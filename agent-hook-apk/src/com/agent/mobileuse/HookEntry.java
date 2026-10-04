package com.agent.mobileuse;

import android.content.Context;
import android.content.Intent;
import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XC_MethodReplacement;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

public class HookEntry implements IXposedHookLoadPackage {

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) throws Throwable {
        // Hook system_server (android / system)
        if ("android".equals(lpparam.packageName) || "system".equals(lpparam.packageName)) {
            hookSystemServer(lpparam);
        }
        // Hook SystemUI (ColorOS Fluid Cloud)
        if ("com.android.systemui".equals(lpparam.packageName)) {
            hookSystemUI(lpparam);
        }
        // Hook self (SettingsActivity activation check)
        if ("com.agent.mobileuse".equals(lpparam.packageName)) {
            hookSelf(lpparam);
        }
    }

    private void hookSelf(XC_LoadPackage.LoadPackageParam lpparam) {
        try {
            Class<?> clazz = XposedHelpers.findClass("com.agent.mobileuse.SettingsActivity", lpparam.classLoader);
            // 不使用 XC_MethodReplacement.returnConstant：该静态工厂方法在 LSPosed IT 分支
            // 并不存在（且编译期 stub 已刻意移除它，让同类错误在编译期就被拦下）。
            // 统一走 returningTrueCallback() 的匿名子类实现。
            XposedBridge.hookAllMethods(clazz, "isModuleActive", returningTrueCallback());
            XposedBridge.log("[AgentMobileUseHook] isModuleActive hooked successfully!");
        } catch (Throwable t) {
            XposedBridge.log("[AgentMobileUseHook] Failed to hook isModuleActive: " + t.getMessage());
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

        // Exclude AgentMobileEdgeGlow window from screenshot capture
        hookEdgeGlowScreenshotExclusion(cl);

        // Intercept Action Button on OnePlus 13 (ColorOS) to launch DemoDialogActivity
        hookActionButton(cl);
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

    private static Object getFieldSafe(Object obj, String fieldName) {
        if (obj == null) return null;
        Class<?> cur = obj.getClass();
        while (cur != null) {
            try {
                java.lang.reflect.Field f = cur.getDeclaredField(fieldName);
                f.setAccessible(true);
                return f.get(obj);
            } catch (NoSuchFieldException e) {
                cur = cur.getSuperclass();
            } catch (Throwable t) {
                return null;
            }
        }
        return null;
    }

    private void hookEdgeGlowScreenshotExclusion(ClassLoader cl) {
        try {
            Class<?> animatorClass = XposedHelpers.findClass("com.android.server.wm.WindowStateAnimator", cl);
            XposedBridge.hookAllMethods(animatorClass, "createSurfaceLocked", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                    Object win = getFieldSafe(param.thisObject, "mWin");
                    if (win == null) return;

                    Object attrsObj = getFieldSafe(win, "mAttrs");
                    if (!(attrsObj instanceof android.view.WindowManager.LayoutParams)) return;
                    android.view.WindowManager.LayoutParams attrs = (android.view.WindowManager.LayoutParams) attrsObj;

                    CharSequence title = attrs.getTitle();
                    if (title == null || !"AgentMobileEdgeGlow".equals(title.toString())) {
                        return;
                    }

                    Object sc = param.getResult();
                    if (sc == null) {
                        sc = getFieldSafe(param.thisObject, "mSurfaceControl");
                    }
                    if (sc == null) {
                        sc = getFieldSafe(win, "mSurfaceControl");
                    }
                    if (sc == null) return;

                    try {
                        Class<?> scClass = Class.forName("android.view.SurfaceControl");
                        Class<?> txClass = Class.forName("android.view.SurfaceControl$Transaction");
                        Object tx = txClass.getConstructor().newInstance();
                        java.lang.reflect.Method setSkipMethod;
                        try {
                            setSkipMethod = txClass.getMethod("setSkipScreenshot", scClass, boolean.class);
                        } catch (NoSuchMethodException e) {
                            setSkipMethod = txClass.getDeclaredMethod("setSkipScreenshot", scClass, boolean.class);
                            setSkipMethod.setAccessible(true);
                        }
                        setSkipMethod.invoke(tx, sc, true);
                        txClass.getMethod("apply").invoke(tx);
                        try {
                            txClass.getMethod("close").invoke(tx);
                        } catch (Throwable ignored) {}
                        XposedBridge.log("[AgentMobileUseHook] SKIP_SCREENSHOT applied to AgentMobileEdgeGlow successfully!");
                    } catch (Throwable t) {
                        XposedBridge.log("[AgentMobileUseHook] Failed to apply SKIP_SCREENSHOT: " + t.getMessage());
                    }
                }
            });
            XposedBridge.log("[AgentMobileUseHook] hookEdgeGlowScreenshotExclusion installed successfully!");
        } catch (Throwable t) {
            XposedBridge.log("[AgentMobileUseHook] Failed to hook hookEdgeGlowScreenshotExclusion: " + t.getMessage());
        }
    }

    private void hookActionButton(ClassLoader cl) {
        try {
            Class<?> strategyClass = XposedHelpers.findClass("com.android.server.policy.StrategyActionButtonKeyLaunchApp", cl);
            XposedBridge.hookAllMethods(strategyClass, "interceptActionKeyDown", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                    android.util.Log.i("AgentMobileUseHook", "Action Button key down intercepted!");
                    Context ctx = null;
                    try {
                        Class<?> cur = param.thisObject.getClass();
                        while (cur != null && ctx == null) {
                            try {
                                java.lang.reflect.Field f = cur.getDeclaredField("mContext");
                                f.setAccessible(true);
                                ctx = (Context) f.get(param.thisObject);
                            } catch (NoSuchFieldException ignored) {
                                cur = cur.getSuperclass();
                            }
                        }
                    } catch (Throwable t) {
                        android.util.Log.w("AgentMobileUseHook", "Could not get mContext via reflection: " + t.getMessage());
                    }

                    if (ctx != null) {
                        try {
                            Intent intent = new Intent();
                            intent.setClassName("com.agent.mobileuse", "com.agent.mobileuse.DemoDialogActivity");
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                            ctx.startActivity(intent);
                            android.util.Log.i("AgentMobileUseHook", "DemoDialogActivity launched successfully from Action Button!");
                        } catch (Throwable t) {
                            android.util.Log.e("AgentMobileUseHook", "Failed to launch DemoDialogActivity: " + t.getMessage(), t);
                        }
                    }
                    param.setResult(null);
                }
            });

            XposedBridge.hookAllMethods(strategyClass, "interceptActionKeyUp", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                    param.setResult(null);
                }
            });

            XposedBridge.log("[AgentMobileUseHook] StrategyActionButtonKeyLaunchApp hooked successfully!");
        } catch (Throwable t) {
            XposedBridge.log("[AgentMobileUseHook] Failed to hook StrategyActionButtonKeyLaunchApp: " + t.getMessage());
        }
    }

    private static Object invokeNoArg(Object obj, String methodName) {
        if (obj == null) return null;
        try {
            java.lang.reflect.Method m = obj.getClass().getMethod(methodName);
            m.setAccessible(true);
            return m.invoke(obj);
        } catch (Throwable t) {
            return null;
        }
    }

    private static boolean isValidAgentLiveAlert(Object sbn) {
        if (sbn == null) return false;
        try {
            String pkg = (String) invokeNoArg(sbn, "getPackageName");
            if (!"com.agent.mobileuse".equals(pkg)) return false;

            Integer id = (Integer) invokeNoArg(sbn, "getId");
            if (id == null || id == 0) return false;

            // Only whitelist our designated Fluid Cloud notification IDs:
            // 10086: GlowService (Capsule: "运行中", "后台接管", "前台接管")
            // 2020:  NotifyReceiver (Task completed card)
            // 20086: QuestionReceiver (Interactive question card)
            if (id != 10086 && id != 2020 && id != 20086) return false;

            Object notif = invokeNoArg(sbn, "getNotification");
            if (notif instanceof android.app.Notification) {
                android.app.Notification n = (android.app.Notification) notif;
                // Exclude Android system AutoGroupSummary notifications (FLAG_GROUP_SUMMARY = 0x200)
                if ((n.flags & 0x00000200) != 0) return false;
                if (n.extras != null) {
                    // Check user personalization switch: Fluid Cloud conversion
                    if (!n.extras.getBoolean("enable_fluid_cloud", true)) {
                        return false;
                    }
                    CharSequence title = n.extras.getCharSequence(android.app.Notification.EXTRA_TITLE);
                    if (title == null || title.toString().trim().isEmpty()) return false;
                }
            }
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    private void hookSystemUI(XC_LoadPackage.LoadPackageParam lpparam) {
        XposedBridge.log("[AgentMobileUseHook] SystemUI loaded: " + lpparam.packageName);
        ClassLoader cl = lpparam.classLoader;

        // 1. Hook OplusLiveAlertFilters.shouldFilter to allow designated com.agent.mobileuse notifications
        try {
            Class<?> filtersClass = XposedHelpers.findClass(
                "com.oplus.systemui.statusbar.notification.livealert.data.repository.OplusLiveAlertFilters",
                cl
            );
            XposedBridge.hookAllMethods(filtersClass, "shouldFilter", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                    if (param.args != null && param.args.length > 0 && param.args[0] != null) {
                        Object entry = param.args[0];
                        try {
                            Object sbn = invokeNoArg(entry, "getSbn");
                            if (sbn != null) {
                                String pkg = (String) invokeNoArg(sbn, "getPackageName");
                                if ("com.agent.mobileuse".equals(pkg)) {
                                    if (isValidAgentLiveAlert(sbn)) {
                                        param.setResult(Boolean.TRUE);
                                    } else {
                                        param.setResult(Boolean.FALSE);
                                    }
                                }
                            }
                        } catch (Throwable ignored) {}
                    }
                }
            });
            XposedBridge.log("[AgentMobileUseHook] OplusLiveAlertFilters.shouldFilter hooked with whitelist filtering!");
        } catch (Throwable t) {
            XposedBridge.log("[AgentMobileUseHook] Failed to hook OplusLiveAlertFilters: " + t.getMessage());
        }

        // 2. Hook OplusLiveAlertFilterByPlugin.shouldFilter (Double insurance)
        try {
            Class<?> pluginFilterClass = XposedHelpers.findClass(
                "com.oplus.systemui.statusbar.notification.livealert.data.repository.OplusLiveAlertFilterByPlugin",
                cl
            );
            XposedBridge.hookAllMethods(pluginFilterClass, "shouldFilter", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                    if (param.args != null && param.args.length > 0 && param.args[0] != null) {
                        Object entry = param.args[0];
                        try {
                            Object sbn = invokeNoArg(entry, "getSbn");
                            if (sbn != null) {
                                String pkg = (String) invokeNoArg(sbn, "getPackageName");
                                if ("com.agent.mobileuse".equals(pkg)) {
                                    if (isValidAgentLiveAlert(sbn)) {
                                        param.setResult(Boolean.TRUE);
                                    } else {
                                        param.setResult(Boolean.FALSE);
                                    }
                                }
                            }
                        } catch (Throwable ignored) {}
                    }
                }
            });
            XposedBridge.log("[AgentMobileUseHook] OplusLiveAlertFilterByPlugin.shouldFilter hooked with whitelist filtering!");
        } catch (Throwable t) {
            XposedBridge.log("[AgentMobileUseHook] Failed to hook OplusLiveAlertFilterByPlugin: " + t.getMessage());
        }
    }
}
