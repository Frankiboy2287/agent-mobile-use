package com.agent.mobileuse;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XC_MethodReplacement;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

public class HookEntry implements IXposedHookLoadPackage {
    public static final String ACTION_GLOW_START = "com.agent.mobileuse.ACTION_GLOW_START";
    public static final String ACTION_GLOW_STOP = "com.agent.mobileuse.ACTION_GLOW_STOP";

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) throws Throwable {
        // 1. Hook system_server (android / system)
        if ("android".equals(lpparam.packageName) || "system".equals(lpparam.packageName)) {
            hookSystemServer(lpparam);
            return;
        }

        // 2. Hook SystemUI for Edge Glow Overlay
        if ("com.android.systemui".equals(lpparam.packageName)) {
            hookSystemUI(lpparam);
        }
    }

    private void hookSystemServer(XC_LoadPackage.LoadPackageParam lpparam) {
        XposedBridge.log("[AgentMobileUseHook] System server loaded: " + lpparam.packageName);
        ClassLoader cl = lpparam.classLoader;

        // Force allow hosting tasks on virtual display
        hookAllMethodsReturningTrue(cl, "android.view.Display", "canHostTasks");
        // Android 17 迁移：LogicalDisplay 已从 com.android.server.wm 移到
        // com.android.server.display（真机 services.jar 实测）。原实现只找 wm 包，
        // 在 API 37 上恒抛 ClassNotFoundException 而被静默吞掉。
        // 两个包名都试一遍，兼容旧版本 ROM。
        hookAllMethodsReturningTrueAnyPackage(cl, "LogicalDisplay", "canHostTasksLocked",
                new String[] {
                    "com.android.server.display.LogicalDisplay",
                    "com.android.server.wm.LogicalDisplay",
                });
        hookAllMethodsReturningTrue(cl, "com.android.server.wm.ActivityTaskSupervisor", "isCallerAllowedToLaunchOnDisplay");
        hookAllMethodsReturningTrue(cl, "com.android.server.wm.ActivityTaskSupervisor", "isCallerAllowedToLaunchOnTaskDisplayArea");
        hookAllMethodsReturningTrue(cl, "com.android.server.wm.ActivityTaskSupervisor", "canPlaceEntityOnDisplay");
        hookAllMethodsReturningTrue(cl, "com.android.server.wm.ActivityRecord", "canBeLaunchedOnDisplay");
        hookAllMethodsReturningTrue(cl, "com.android.server.wm.Task", "canBeLaunchedOnDisplay");
        hookAllMethodsReturningTrue(cl, "com.android.server.wm.RootWindowContainer", "canLaunchOnDisplay");
        hookAllMethodsReturningTrue(cl, "com.android.server.display.DisplayManagerService", "validatePackageName");

        // Isolate InputMethodManagerService (IME) to prevent soft keyboard popup on Display 0
        hookImmsDisplayIsolation(cl);
    }

    private void hookSystemUI(XC_LoadPackage.LoadPackageParam lpparam) {
        XposedBridge.log("[AgentMobileUseHook] SystemUI loaded. Setting up Edge Glow receiver...");
        final ClassLoader cl = lpparam.classLoader;

        try {
            // Hook Application#onCreate to get Context
            XposedHelpers.findAndHookMethod(
                "android.app.Application",
                cl,
                "onCreate",
                new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                        final Context context = (Context) param.thisObject;
                        if (context == null) return;

                        android.util.Log.i("AgentMobileUseHook", "SystemUI Application onCreate hooked! Registering glow receiver...");

                        IntentFilter filter = new IntentFilter();
                        filter.addAction(ACTION_GLOW_START);
                        filter.addAction(ACTION_GLOW_STOP);

                        // BroadcastReceiver for glow control
                        BroadcastReceiver receiver = new BroadcastReceiver() {
                            @Override
                            public void onReceive(Context ctx, Intent intent) {
                                String action = intent.getAction();
                                android.util.Log.i("AgentMobileUseHook", "Received glow broadcast: " + action);
                                if (ACTION_GLOW_START.equals(action)) {
                                    EdgeGlowController.getInstance(ctx).showGlow();
                                } else if (ACTION_GLOW_STOP.equals(action)) {
                                    EdgeGlowController.getInstance(ctx).hideGlow();
                                }
                            }
                        };

                        // Register receiver (Android 14+ RECEIVER_EXPORTED = 2 via reflection)
                        try {
                            java.lang.reflect.Method regMethod = Context.class.getMethod("registerReceiver", BroadcastReceiver.class, IntentFilter.class, int.class);
                            regMethod.invoke(context, receiver, filter, 2);
                        } catch (Throwable t) {
                            context.registerReceiver(receiver, filter);
                        }

                        android.util.Log.i("AgentMobileUseHook", "Edge Glow receiver registered successfully in SystemUI!");
                    }
                }
            );
        } catch (Throwable t) {
            XposedBridge.log("[AgentMobileUseHook] Failed to hook SystemUI: " + t.getMessage());
        }
    }

    private void hookAllMethodsReturningTrue(ClassLoader cl, String className, String methodName) {
        try {
            Class<?> clazz = XposedHelpers.findClass(className, cl);
            java.util.Set<?> unhooks = XposedBridge.hookAllMethods(clazz, methodName, returningTrueCallback());
            // 成功也要记日志。原实现只在失败时记录，导致"一个 hook 都没成功"和
            // "全部成功"在日志上几乎同样安静 —— 排查时无法区分这两种状态。
            int n = (unhooks == null) ? -1 : unhooks.size();
            XposedBridge.log("[AgentMobileUseHook] Hooked " + className + "#" + methodName
                    + (n >= 0 ? " (" + n + " overload(s))" : ""));
        } catch (Throwable t) {
            XposedBridge.log("[AgentMobileUseHook] Failed to hook " + className + "#" + methodName + ": " + t.getMessage());
        }
    }

    /**
     * 依次尝试多个候选包名，命中第一个存在的即返回。
     *
     * 用于类在 Android 版本间发生过包名迁移的场景（如 LogicalDisplay 从
     * com.android.server.wm 迁到 com.android.server.display），避免写死单一包名后
     * 在新 ROM 上恒抛 ClassNotFoundException。
     */
    private void hookAllMethodsReturningTrueAnyPackage(ClassLoader cl, String simpleName,
                                                       String methodName, String[] candidates) {
        for (String candidate : candidates) {
            try {
                Class<?> clazz = XposedHelpers.findClass(candidate, cl);
                XposedBridge.hookAllMethods(clazz, methodName, returningTrueCallback());
                XposedBridge.log("[AgentMobileUseHook] Hooked " + candidate + "#" + methodName);
                return;
            } catch (Throwable t) {
                // 试下一个候选包名；全部失败时在循环外统一记录
            }
        }
        XposedBridge.log("[AgentMobileUseHook] Failed to hook " + simpleName + "#" + methodName
                + ": 所有候选包名均不可用 " + java.util.Arrays.toString(candidates));
    }

    /**
     * 构造一个「无条件返回 true」的替换回调。
     *
     * 不使用 {@code XC_MethodReplacement.returnConstant(Boolean.TRUE)}：该静态工厂方法
     * 在部分 Xposed/LSPosed 分支（实测 LSPosed IT v2.2.0）中并不存在，调用会抛
     *   No static method returnConstant(Ljava/lang/Object;)Lde/robv/android/xposed/XC_MethodHook;
     * 导致**每一个 hook 都静默失败**（异常被 catch 后只写一行日志）。
     *
     * 改为匿名子类覆写 replaceHookedMethod，这是 Xposed API 中语义最基础、
     * 各分支实现都 guaranteed 支持的路径：覆写后原方法体不再执行，直接返回我们的值。
     */
    private static XC_MethodReplacement returningTrueCallback() {
        return new XC_MethodReplacement() {
            @Override
            protected Object replaceHookedMethod(MethodHookParam param) throws Throwable {
                return Boolean.TRUE;
            }
        };
    }

    private void hookImmsDisplayIsolation(ClassLoader cl) {
        try {
            Class<?> imms = XposedHelpers.findClass("com.android.server.inputmethod.InputMethodManagerService", cl);
            XposedBridge.hookAllMethods(imms, "computeImeDisplayIdForTarget", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                    int displayId = (int) param.args[0];
                    if (displayId != 0) {
                        param.setResult(displayId);
                    }
                }
            });
        } catch (Throwable t) {
            XposedBridge.log("[AgentMobileUseHook] Failed to hook IMMS: " + t.getMessage());
        }
    }
}
