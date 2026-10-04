SKIPUNZIP=0

# =============================================================================
# customize.sh — Agent Mobile Use 模块安装脚本
#
# 设计原则：安装过程「安静」——只打印关键结果，不刷屏。
#   * Hook APK 安装 / 运行时部署：各一行结果
#   * LSPosed 作用域：尽力写入；失败不阻塞（重启后在 LSPosed 里勾选即可），
#     因此不再打印大段手动激活指引
#   * 详细环境诊断交给安装后的 `vd doctor`
# =============================================================================

HOOK_PKG="com.agent.mobileuse"
LSP_DB="/data/adb/lspd/config/modules_config.db"
SQLITE_BIN="$MODPATH/bin/sqlite3"

ui_print "**********************************************"
ui_print "*   Agent Mobile Use v0.8.5-alpha (Xiaomi)   *"
ui_print "**********************************************"

# ---------------------------------------------------------------------------
# 1. 安装 Hook APK
# ---------------------------------------------------------------------------
APK_SRC="$MODPATH/apk/agent_hook.apk"
if [ -f "$APK_SRC" ]; then
    # 已装同包名时先卸载，避免签名不一致导致安装失败
    if pm path "$HOOK_PKG" >/dev/null 2>&1; then
        pm uninstall "$HOOK_PKG" >/dev/null 2>&1
    fi
    pm install -r "$APK_SRC" >/dev/null 2>&1
    if pm path "$HOOK_PKG" >/dev/null 2>&1; then
        ui_print "- Hook 补丁: 已安装"
        pm grant "$HOOK_PKG" android.permission.RECORD_AUDIO >/dev/null 2>&1
    else
        ui_print "! Hook 补丁安装失败（请解锁屏幕后重试）: $APK_SRC"
    fi
else
    ui_print "! 模块包内缺少 apk/agent_hook.apk"
fi

# ---------------------------------------------------------------------------
# 2. 配置 LSPosed 作用域（静默；失败不阻塞安装）
# ---------------------------------------------------------------------------
if [ -f "$LSP_DB" ] && [ -x "$SQLITE_BIN" ]; then
    APK_PATH=$(pm path "$HOOK_PKG" 2>/dev/null | head -n 1 | cut -d':' -f2)
    if [ -n "$APK_PATH" ]; then
        "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO modules (module_pkg_name, apk_path) VALUES ('$HOOK_PKG', '$APK_PATH');" 2>/dev/null
        "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO modules_state (module_pkg_name, user_id, enabled) VALUES ('$HOOK_PKG', 0, 1);" 2>/dev/null
        "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO scope (module_pkg_name, app_pkg_name, user_id) VALUES ('$HOOK_PKG', 'android', 0);" 2>/dev/null
        "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO scope (module_pkg_name, app_pkg_name, user_id) VALUES ('$HOOK_PKG', 'system', 0);" 2>/dev/null
        "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO scope (module_pkg_name, app_pkg_name, user_id) VALUES ('$HOOK_PKG', 'com.android.systemui', 0);" 2>/dev/null
        "$SQLITE_BIN" "$LSP_DB" "INSERT OR REPLACE INTO scope (module_pkg_name, app_pkg_name, user_id) VALUES ('$HOOK_PKG', 'com.agent.mobileuse', 0);" 2>/dev/null
    fi
else
    ui_print "- 提示: 未检测到 LSPosed 数据库，Hook 功能需自行配置"
fi

# ---------------------------------------------------------------------------
# 3. 权限与运行时部署（静默）
# ---------------------------------------------------------------------------
chmod 755 "$SQLITE_BIN" 2>/dev/null

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/bin/vd" 0 0 0755
set_perm "$MODPATH/bin/run_daemon.sh" 0 0 0755
set_perm "$MODPATH/bin/vd_server" 0 0 0755
set_perm "$MODPATH/bin/sqlite3" 0 0 0755
set_perm "$MODPATH/bin/vd_env.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755

cp -f "$MODPATH/bin/agent_vd.dex"    /data/local/tmp/agent_vd.dex    2>/dev/null
cp -f "$MODPATH/bin/agent_tools.dex" /data/local/tmp/agent_tools.dex 2>/dev/null
cp -f "$MODPATH/bin/run_daemon.sh"   /data/local/tmp/run_daemon.sh   2>/dev/null
cp -f "$MODPATH/bin/vd_env.sh"       /data/local/tmp/vd_env.sh       2>/dev/null
chmod 755 /data/local/tmp/run_daemon.sh /data/local/tmp/vd_env.sh 2>/dev/null
chmod 644 /data/local/tmp/agent_vd.dex /data/local/tmp/agent_tools.dex 2>/dev/null
# 清掉上一版可能残留的 classpath 缓存，避免 OTA 后沿用旧 jar 列表
rm -f /data/local/tmp/vd_bootclasspath.txt 2>/dev/null

ui_print "- 运行时: 已部署到 /data/local/tmp"
ui_print "- 安装完成，重启手机生效"
ui_print "**********************************************"
