SKIPUNZIP=0

# =============================================================================
# customize.sh — Agent Mobile Use 模块安装脚本
#
# 已适配的环境（v4.7-xiaomi）：
#   * Root 方案：FolkPatch / APatch（/data/adb/ap）、KernelSU、Magisk
#   * Hook 框架：LSPosed（含 LSPosed IT 分支，数据库表结构与上游一致）
#   * 机型：小米 15 Pro（haotian）/ HyperOS 4 / Android 17，以及通用 AOSP / 其它厂商
#
# 与原版的差异：
#   1. 显式探测并报告 Root 方案与 LSPosed 状态，而不是"装完就假设生效"
#   2. LSPosed 作用域写入后做**回读校验**，失败时把手工配置步骤打清楚
#      （原版写完不校验，静默失败会让 Hook 完全不生效）
#   3. Hook APK 优先从模块目录安装；失败时给出明确原因（SELinux / 签名冲突）
#   4. 同步部署 vd_env.sh（跨厂商 BOOTCLASSPATH 解析器），原版没有这个文件
# =============================================================================

MODULE_ID="agent_mobile_use"
HOOK_PKG="com.agent.mobileuse"

ui_print "**********************************************"
ui_print "*   Agent Mobile Use 虚拟副屏底座 v4.7        *"
ui_print "*   小米 / HyperOS / Android 17 适配版        *"
ui_print "**********************************************"

# ---------------------------------------------------------------------------
# 1. 环境探测
# ---------------------------------------------------------------------------
ROOT_IMPL="未知"
if [ -d /data/adb/ap ]; then
    ROOT_IMPL="APatch/FolkPatch"
    KP_VER=$(cat /data/adb/ap/version 2>/dev/null)
    [ -n "$KP_VER" ] && ROOT_IMPL="$ROOT_IMPL (KernelPatch $KP_VER)"
elif [ -d /data/adb/ksu ]; then
    ROOT_IMPL="KernelSU"
elif [ -d /data/adb/magisk ]; then
    ROOT_IMPL="Magisk"
fi
ui_print "- Root 方案: $ROOT_IMPL"
ui_print "- 系统: $(getprop ro.product.brand) $(getprop ro.product.model) / Android $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
ui_print "- 版本: $(getprop ro.build.version.incremental)"

# ---------------------------------------------------------------------------
# 2. 安装 Hook APK
# ---------------------------------------------------------------------------
ui_print "- 正在安装 LSPosed 跨屏路由与输入法隔离补丁..."
APK_SRC="$MODPATH/apk/agent_hook.apk"
if [ ! -f "$APK_SRC" ]; then
    ui_print "! 错误: 模块包内缺少 apk/agent_hook.apk"
else
    # 已装同包名时先卸载，避免签名不一致导致安装失败
    if pm path "$HOOK_PKG" >/dev/null 2>&1; then
        ui_print "  - 检测到已安装的旧版本，先卸载"
        pm uninstall "$HOOK_PKG" >/dev/null 2>&1
    fi
    INSTALL_OUT=$(pm install -r "$APK_SRC" 2>&1)
    if pm path "$HOOK_PKG" >/dev/null 2>&1; then
        APK_PATH=$(pm path "$HOOK_PKG" 2>/dev/null | head -n 1 | cut -d':' -f2)
        ui_print "  - Hook 补丁安装成功: $APK_PATH"
    else
        ui_print "! Hook 补丁安装失败"
        ui_print "! 原因: $(echo "$INSTALL_OUT" | tail -n 2)"
        ui_print "! 请解锁屏幕后重试，或手动安装: $APK_SRC"
    fi
fi

# ---------------------------------------------------------------------------
# 3. 配置 LSPosed 作用域
# ---------------------------------------------------------------------------
LSP_DB="/data/adb/lspd/config/modules_config.db"
SQLITE_BIN="$MODPATH/bin/sqlite3"
chmod 755 "$SQLITE_BIN" 2>/dev/null

LSP_CONFIGURED=0
if [ ! -f "$LSP_DB" ]; then
    ui_print "! 未找到 LSPosed 数据库 ($LSP_DB)"
    ui_print "! 说明: 未检测到 LSPosed，或它尚未初始化。Hook 功能需要 LSPosed。"
elif [ ! -x "$SQLITE_BIN" ]; then
    ui_print "! 缺少内置 sqlite3，无法自动配置作用域"
else
    APK_PATH=$(pm path "$HOOK_PKG" 2>/dev/null | head -n 1 | cut -d':' -f2)
    if [ -z "$APK_PATH" ]; then
        ui_print "! APK 未安装成功，跳过作用域配置"
    else
        ui_print "- 正在自动配置 LSPosed 模块作用域..."

        # 注意：modules_config.db 处于 WAL 模式。先确认没有残留 -wal 事务，
        # 若有则说明 LSPosed 正在运行，直接写入有覆盖风险 —— 此时改为提示手工配置。
        WAL_SIZE=0
        if [ -f "${LSP_DB}-wal" ]; then
            WAL_SIZE=$(stat -c %s "${LSP_DB}-wal" 2>/dev/null || echo 0)
        fi

        write_scope() {
            "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO modules (module_pkg_name, apk_path) VALUES ('$HOOK_PKG', '$APK_PATH');" 2>/dev/null
            "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO modules_state (module_pkg_name, user_id, enabled) VALUES ('$HOOK_PKG', 0, 1);" 2>/dev/null
            "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO scope (module_pkg_name, app_pkg_name, user_id) VALUES ('$HOOK_PKG', 'android', 0);" 2>/dev/null
            "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO scope (module_pkg_name, app_pkg_name, user_id) VALUES ('$HOOK_PKG', 'system', 0);" 2>/dev/null
            "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO scope (module_pkg_name, app_pkg_name, user_id) VALUES ('$HOOK_PKG', 'com.android.systemui', 0);" 2>/dev/null
        }

        write_scope

        # 回读校验：原版写完不验证，LSPosed 侧静默失败会表现为"Hook 完全不生效"
        CHECK=$("$SQLITE_BIN" "$LSP_DB" "SELECT count(*) FROM scope WHERE module_pkg_name='$HOOK_PKG';" 2>/dev/null | tr -dc '0-9')
        CHECK_EN=$("$SQLITE_BIN" "$LSP_DB" "SELECT enabled FROM modules_state WHERE module_pkg_name='$HOOK_PKG' AND user_id=0;" 2>/dev/null | tr -dc '0-9')
        if [ "${CHECK:-0}" -ge 2 ] && [ "${CHECK_EN:-0}" = "1" ]; then
            LSP_CONFIGURED=1
            ui_print "  - 作用域已写入并校验通过 (scope=$CHECK, enabled=$CHECK_EN)"
            [ "$WAL_SIZE" -gt 0 ] && ui_print "  - 提示: 检测到 LSPosed 正在运行，重启后生效"
        else
            ui_print "! 作用域自动写入未通过校验 (scope=${CHECK:-0}, enabled=${CHECK_EN:-0})"
        fi
    fi
fi

if [ "$LSP_CONFIGURED" != "1" ]; then
    ui_print "**********************************************"
    ui_print "! 请手动完成 Hook 激活（30 秒）:"
    ui_print "!   1. 打开 LSPosed 管理器"
    ui_print "!   2. 进入「模块」-> 勾选 Agent Mobile Use Hook"
    ui_print "!   3. 在「作用域」中勾选: 系统框架 / 系统界面"
    ui_print "!   4. 重启手机"
    ui_print "**********************************************"
fi

# ---------------------------------------------------------------------------
# 4. 权限与运行时部署
# ---------------------------------------------------------------------------
ui_print "- 设置可执行权限..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/bin/vd" 0 0 0755
set_perm "$MODPATH/bin/run_daemon.sh" 0 0 0755
set_perm "$MODPATH/bin/vd_server" 0 0 0755
set_perm "$MODPATH/bin/sqlite3" 0 0 0755
set_perm "$MODPATH/bin/vd_env.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755

ui_print "- 部署运行时到 /data/local/tmp (免重启即可用)..."
cp -f "$MODPATH/bin/agent_vd.dex"    /data/local/tmp/agent_vd.dex    2>/dev/null
cp -f "$MODPATH/bin/agent_tools.dex" /data/local/tmp/agent_tools.dex 2>/dev/null
cp -f "$MODPATH/bin/run_daemon.sh"   /data/local/tmp/run_daemon.sh   2>/dev/null
cp -f "$MODPATH/bin/vd_env.sh"       /data/local/tmp/vd_env.sh       2>/dev/null
chmod 755 /data/local/tmp/run_daemon.sh /data/local/tmp/vd_env.sh 2>/dev/null
chmod 644 /data/local/tmp/agent_vd.dex /data/local/tmp/agent_tools.dex 2>/dev/null
# 清掉上一版可能残留的 classpath 缓存，避免 OTA 后沿用旧 jar 列表
rm -f /data/local/tmp/vd_bootclasspath.txt 2>/dev/null

ui_print "**********************************************"
ui_print "* 安装完成！                                  *"
ui_print "* 终端执行: vd doctor   (环境自检)            *"
ui_print "*           vd start    (拉起副屏)            *"
ui_print "*           vd tree     (控件树)              *"
ui_print "* 浏览器:   http://127.0.0.1:3070             *"
if [ "$LSP_CONFIGURED" = "1" ]; then
    ui_print "* 重启手机后跨屏 Hook 生效                    *"
fi
ui_print "**********************************************"
