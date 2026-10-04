package com.agent;

import android.os.IBinder;
import java.lang.reflect.Method;

/**
 * ImePolicyHelper — 在 app_process 进程中设置虚拟屏的 IME 策略。
 *
 * 背景（Xiaomi 15 Pro / HyperOS 4 / Android 17 实测）：
 * DaemonMain 原实现走
 *     WindowManagerGlobal.getWindowManagerService().setDisplayImePolicy(id, 0)
 * 在 API 37 上必然失败。真机取到的根因是：
 *     java.lang.IllegalStateException: ApplicationSharedMemory not initialized
 *         at com.android.internal.os.ApplicationSharedMemory.getInstance(ApplicationSharedMemory.java:81)
 *         at android.view.WindowManagerGlobal.getWindowManagerService(WindowManagerGlobal.java:301)
 * Android 17 给 WindowManagerGlobal 引入了 ApplicationSharedMemory 依赖，而 app_process
 * 直接拉起的进程不会初始化它（那是 zygote/app 进程的职责），所以该静态方法恒抛异常。
 * 原代码把异常 getMessage() 打出来是 null，看起来像"方法不存在"，实际是初始化缺失。
 *
 * 绕行方案（已在真机验证成功）：
 *     ServiceManager.getService("window") -> IWindowManager$Stub.asInterface -> setDisplayImePolicy
 * 该路径不经过 WindowManagerGlobal，实测 setDisplayImePolicy(4, 0) 调用成功，且
 * getDisplayImePolicy(4) 回读为 0，确认策略真正落到了 DisplayContent 上。
 *
 * 策略常量（frameworks/base DisplayContent）：
 *     0 = DISPLAY_IME_POLICY_LOCAL        输入法跟随该显示器（副屏需要的行为）
 *     1 = DISPLAY_IME_POLICY_FALLBACK_DISPLAY
 *     2 = DISPLAY_IME_POLICY_HIDE         完全隐藏输入法
 */
final class ImePolicyHelper {

    static final int POLICY_LOCAL = 0;
    static final int POLICY_FALLBACK = 1;
    static final int POLICY_HIDE = 2;

    private ImePolicyHelper() {}

    /** 解析 IWindowManager 代理；失败返回 null。 */
    private static Object resolveWindowManager() {
        try {
            Class<?> serviceManager = Class.forName("android.os.ServiceManager");
            Method getService = serviceManager.getMethod("getService", String.class);
            IBinder binder = (IBinder) getService.invoke(null, "window");
            if (binder == null) return null;
            Class<?> stub = Class.forName("android.view.IWindowManager$Stub");
            Method asInterface = stub.getMethod("asInterface", IBinder.class);
            return asInterface.invoke(null, binder);
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * 设置指定显示器的 IME 策略。
     *
     * @return null 表示成功；否则返回失败原因（便于上报而不是静默降级）
     */
    static String setDisplayImePolicy(int displayId, int policy) {
        Object wm = resolveWindowManager();
        if (wm == null) return "IWindowManager 不可用 (ServiceManager window 服务解析失败)";
        try {
            Method set = null;
            for (Method m : wm.getClass().getMethods()) {
                if ("setDisplayImePolicy".equals(m.getName()) && m.getParameterTypes().length == 2) {
                    set = m;
                    break;
                }
            }
            if (set == null) return "IWindowManager 上没有 setDisplayImePolicy(int,int)";
            set.invoke(wm, displayId, policy);
        } catch (Throwable t) {
            Throwable cause = (t.getCause() != null) ? t.getCause() : t;
            return cause.getClass().getSimpleName() + ": " + cause.getMessage();
        }
        // 回读校验：确认策略真的生效，而不是"调用没抛异常"就算成功
        Integer actual = getDisplayImePolicy(displayId);
        if (actual == null) return null; // 无法回读时不阻塞（部分 ROM 未暴露 getter）
        if (actual != policy) return "策略未生效: 期望 " + policy + " 实际 " + actual;
        return null;
    }

    /** 回读当前 IME 策略；失败返回 null。 */
    static Integer getDisplayImePolicy(int displayId) {
        Object wm = resolveWindowManager();
        if (wm == null) return null;
        try {
            Method get = null;
            for (Method m : wm.getClass().getMethods()) {
                if ("getDisplayImePolicy".equals(m.getName()) && m.getParameterTypes().length == 1) {
                    get = m;
                    break;
                }
            }
            if (get == null) return null;
            Object r = get.invoke(wm, displayId);
            if (r instanceof Integer) return (Integer) r;
            return null;
        } catch (Throwable t) {
            return null;
        }
    }
}
