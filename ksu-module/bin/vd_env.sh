#!/system/bin/sh
# =============================================================================
# vd_env.sh — 跨厂商 BOOTCLASSPATH 解析器
#
# 背景：原项目把 ColorOS/OPPO 专属的 BOOTCLASSPATH 硬编码进了 vd 与
# run_daemon.sh（含 oplus-framework.jar、subsystem-framework.jar、qcom.fmradio.jar）。
# 在小米 / 三星 / AOSP 等设备上这些 jar 并不存在，ART 会在启动 app_process 时
# 直接 SIGABRT：
#     Check failed: !location.empty() BOOTCLASSPATH and DEXOATBOOTCLASSPATH must not empty
# 即使只是"路径不存在"也会导致同样的崩溃，因此必须逐项做存在性过滤。
#
# 策略（按优先级）：
#   1. 从 zygote 进程的 /proc/<pid>/environ 读取系统真实 BOOTCLASSPATH 并逐项校验存在性
#      —— 这是唯一能 100% 覆盖厂商定制 jar（miui-framework / xiaomi-framework 等）的方式；
#   2. 回退：扫描 /apex/*/javalib 与各 framework 目录，动态拼装并过滤；
#   3. 结果按设备缓存到 /data/local/tmp/vd_bootclasspath.txt
#
# 被 vd 与 run_daemon.sh 共同 source，避免两份硬编码漂移。
# =============================================================================

VD_BC_CACHE="/data/local/tmp/vd_bootclasspath.txt"

# _vd_filter_classpath <raw-colon-path> [exclude-extra-regex]
#   逐项保留「真实存在的文件」；可选地再排除匹配 regex 的项。
_vd_filter_classpath() {
    _raw="$1"
    _excl="$2"
    _out=""
    _oldifs="$IFS"
    IFS=':'
    for _p in $_raw; do
        [ -z "$_p" ] && continue
        [ -f "$_p" ] || continue
        if [ -n "$_excl" ]; then
            case "$_p" in
                $_excl) continue ;;
            esac
        fi
        if [ -z "$_out" ]; then _out="$_p"; else _out="$_out:$_p"; fi
    done
    IFS="$_oldifs"
    echo "$_out"
}

# _vd_cache_key — 设备+版本指纹，避免跨 OTA 复用旧缓存
_vd_cache_key() {
    _dev=$(getprop ro.product.device 2>/dev/null)
    _rel=$(getprop ro.build.version.release 2>/dev/null)
    _inc=$(getprop ro.build.version.incremental 2>/dev/null)
    echo "${_dev:-unknown}_${_rel:-0}_${_inc:-0}"
}

# _vd_resolve_bootclasspath — 产出最终 BOOTCLASSPATH 到 stdout
_vd_resolve_bootclasspath() {
    _key=$(_vd_cache_key)
    if [ -f "$VD_BC_CACHE" ]; then
        _cached_key=$(head -n 1 "$VD_BC_CACHE" 2>/dev/null)
        _cached_bp=$(sed -n '2p' "$VD_BC_CACHE" 2>/dev/null)
        if [ "$_cached_key" = "$_key" ] && [ -n "$_cached_bp" ]; then
            # 缓存也必须复验：OTA 或模块卸载后 jar 可能消失
            _ok=1
            _oldifs="$IFS"; IFS=':'
            for _p in $_cached_bp; do
                [ -f "$_p" ] || { _ok=0; break; }
            done
            IFS="$_oldifs"
            if [ "$_ok" = "1" ]; then
                echo "$_cached_bp"
                return 0
            fi
        fi
    fi

    _bp=""

    # --- 策略 1: 从 zygote 读取系统真实 classpath ---------------------------
    # 注意：zygote 的 BOOTCLASSPATH 含完整厂商 jar 链，是权威来源。
    # 但 DEX2OATBOOTCLASSPATH 是"编译期"子集，直接当运行期 BOOTCLASSPATH 用会
    # 丢掉 framework-*.jar，故两者分开处理。
    _zygote_raw=""
    if [ -r /proc/1/environ ]; then
        _zygote_raw=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep '^BOOTCLASSPATH=' | head -n 1 | cut -d= -f2-)
    fi
    if [ -z "$_zygote_raw" ]; then
        # pgrep -f 在小内存/严格 SELinux 下可能不可用，pidof 作为备选
        _zp=""
        if command -v pgrep >/dev/null 2>&1; then
            _zp=$(pgrep -f zygote 2>/dev/null | head -n 1)
        fi
        if [ -z "$_zp" ] && command -v pidof >/dev/null 2>&1; then
            _zp=$(pidof zygote64 2>/dev/null | awk '{print $1}')
            [ -z "$_zp" ] && _zp=$(pidof zygote 2>/dev/null | awk '{print $1}')
        fi
        if [ -n "$_zp" ] && [ -r "/proc/$_zp/environ" ]; then
            _zygote_raw=$(tr '\0' '\n' < "/proc/$_zp/environ" 2>/dev/null | grep '^BOOTCLASSPATH=' | head -n 1 | cut -d= -f2-)
        fi
    fi
    if [ -n "$_zygote_raw" ]; then
        _bp=$(_vd_filter_classpath "$_zygote_raw")
    fi

    # --- 策略 2: 动态扫描拼装 ----------------------------------------------
    if [ -z "$_bp" ]; then
        _cand=""
        # 2a) APEX javalib（跨版本路径差异较大，故按目录扫描而非写死文件名）
        for _d in /apex/com.android.art/javalib /apex/com.android.i18n/javalib \
                  /apex/com.android.conscrypt/javalib; do
            [ -d "$_d" ] || continue
            for _f in "$_d"/*.jar; do
                [ -f "$_f" ] && _cand="$_cand:$_f"
            done
        done
        # 2b) 核心 framework jar（顺序敏感：core 在前）
        for _f in framework.jar framework-graphics.jar framework-location.jar ext.jar \
                  telephony-common.jar voip-common.jar ims-common.jar \
                  framework-ondeviceintelligence-platform.jar framework-nfc.jar; do
            [ -f "/system/framework/$_f" ] && _cand="$_cand:/system/framework/$_f"
        done
        # 2c) 厂商定制 jar：整个目录扫描，自动适配 MIUI/HyperOS/ColorOS/OneUI
        for _d in /system_ext/framework /system/framework; do
            [ -d "$_d" ] || continue
            for _f in "$_d"/*.jar; do
                case "$_f" in
                    */framework.jar|*/framework-graphics.jar|*/framework-location.jar|*/ext.jar|\
                    */telephony-common.jar|*/voip-common.jar|*/ims-common.jar|\
                    */framework-ondeviceintelligence-platform.jar|*/framework-nfc.jar) continue ;;
                esac
                # 排除非 bootclasspath 用途的 jar（services/am/bmgr 等在 SYSTEMSERVERCLASSPATH）
                case "$_f" in
                    */services.jar|*/am.jar|*/bmgr.jar|*/bu.jar|*/content.jar|*/hid.jar|\
                    */incident-helper-cmd.jar|*/input.jar|*/monkey.jar|*/pm.jar|*/requestsync.jar|\
                    */sm.jar|*/svc.jar|*/telecom.jar|*/uiautomator.jar|*/uinput.jar|*/vr.jar|\
                    */apple*) continue ;;
                esac
                _cand="$_cand:$_f"
            done
        done
        # 2d) APEX 其余 framework-*.jar（adservices / permission / wifi 等）
        for _d in /apex/*/javalib; do
            [ -d "$_d" ] || continue
            case "$_d" in
                */com.android.art/*|*/com.android.i18n/*|*/com.android.conscrypt/*) continue ;;
            esac
            for _f in "$_d"/framework-*.jar "$_d"/conscrypt.jar "$_d"/updatable-media.jar \
                      "$_d"/android.net.ipsec.ike.jar; do
                [ -f "$_f" ] && _cand="$_cand:$_f"
            done
        done
        _bp=$(_vd_filter_classpath "$_cand")
    fi

    if [ -n "$_bp" ]; then
        { echo "$_key"; echo "$_bp"; } > "$VD_BC_CACHE" 2>/dev/null
        chmod 644 "$VD_BC_CACHE" 2>/dev/null
    fi
    echo "$_bp"
}

# _vd_resolve_dex2oat_bootclasspath — 编译期列表，缺省时用 BOOTCLASSPATH 前段
_vd_resolve_dex2oat_bootclasspath() {
    _raw=""
    if [ -r /proc/1/environ ]; then
        _raw=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep '^DEX2OATBOOTCLASSPATH=' | head -n 1 | cut -d= -f2-)
    fi
    if [ -z "$_raw" ] && command -v pgrep >/dev/null 2>&1; then
        _zp=$(pgrep -f zygote 2>/dev/null | head -n 1)
        if [ -n "$_zp" ] && [ -r "/proc/$_zp/environ" ]; then
            _raw=$(tr '\0' '\n' < "/proc/$_zp/environ" 2>/dev/null | grep '^DEX2OATBOOTCLASSPATH=' | head -n 1 | cut -d= -f2-)
        fi
    fi
    if [ -n "$_raw" ]; then
        _vd_filter_classpath "$_raw"
        return 0
    fi
    # 回退：取 BOOTCLASSPATH 中 /apex 与 /system/framework 的核心部分
    echo "$1" | tr ':' '\n' | grep -E '^/apex/com\.android\.(art|i18n)/javalib/|^/system/framework/(framework|ext|telephony-common|voip-common|ims-common)' | tr '\n' ':' | sed 's/:$//'
}

# vd_export_app_process_env — 建立 app_process 运行所需的完整环境
#   必须在 source 后调用；会自动设置 BOOTCLASSPATH / DEX2OATBOOTCLASSPATH
vd_export_app_process_env() {
    export ANDROID_ROOT=/system
    export ANDROID_DATA=/data
    export ANDROID_ART_ROOT=/apex/com.android.art
    export ANDROID_I18N_ROOT=/apex/com.android.i18n
    export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata
    [ -d /apex/com.android.i18n ] || unset ANDROID_I18N_ROOT
    [ -d /apex/com.android.tzdata ] || unset ANDROID_TZDATA_ROOT
    # ANDROID_ASSETS 缺失会让某些厂商 framework 初始化失败
    [ -n "$ANDROID_ASSETS" ] || export ANDROID_ASSETS=/system/app
    [ -n "$ANDROID_STORAGE" ] || export ANDROID_STORAGE=/storage

    _bp=$(_vd_resolve_bootclasspath)
    if [ -z "$_bp" ]; then
        echo "[vd_env] 致命错误: 无法解析 BOOTCLASSPATH" >&2
        return 1
    fi
    export BOOTCLASSPATH="$_bp"

    _d2o=$(_vd_resolve_dex2oat_bootclasspath "$_bp")
    if [ -n "$_d2o" ]; then
        export DEX2OATBOOTCLASSPATH="$_d2o"
    else
        export DEX2OATBOOTCLASSPATH="$_bp"
    fi
    return 0
}

# vd_bootclasspath_summary — 诊断输出（vd doctor 用）
vd_bootclasspath_summary() {
    echo "设备指纹: $(_vd_cache_key)"
    echo "缓存文件: $VD_BC_CACHE $([ -f "$VD_BC_CACHE" ] && echo '(存在)' || echo '(不存在)')"
    _bp=$(_vd_resolve_bootclasspath)
    _n=$(echo "$_bp" | tr ':' '\n' | grep -c .)
    echo "BOOTCLASSPATH 条目数: $_n"
    echo "$_bp" | tr ':' '\n' | while read -r _l; do [ -n "$_l" ] && echo "  $_l"; done
    # 厂商定制 jar 识别
    echo "$_bp" | tr ':' '\n' | grep -E 'miui|xiaomi|oplus|oneplus|samsung|sec-|qti|vendor\.' | while read -r _l; do
        echo "  [厂商定制] $_l"
    done
}
