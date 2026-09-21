#!/system/bin/sh
# =============================================================================
# run_daemon.sh — 启动虚拟副屏守护进程 (DaemonMain)
#
# 适配说明（v4.7-xiaomi）：
#   * BOOTCLASSPATH 原本硬编码 ColorOS/OPPO 专属 jar（oplus-framework.jar /
#     subsystem-framework.jar / qcom.fmradio.jar）。在小米 HyperOS 上这些文件
#     不存在，ART 会以
#         Check failed: !location.empty() BOOTCLASSPATH and DEXOATBOOTCLASSPATH must not empty
#     直接 SIGABRT。现改为 source bin/vd_env.sh 动态解析并逐项校验存在性。
#   * 分辨率探测改为「优先 Override size，退化到 Physical size」，避免用户改过
#     分辨率/DPI 后副屏尺寸与主屏逻辑尺寸不一致导致坐标错位。
# =============================================================================
MODDIR="/data/adb/modules/agent_mobile_use"
if [ ! -d "$MODDIR" ]; then
    MODDIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
fi
[ -d "$MODDIR" ] || MODDIR="/data/local/tmp"

DEX_PATH="$MODDIR/bin/agent_vd.dex"
VD_ENV="$MODDIR/bin/vd_env.sh"
[ -f "$DEX_PATH" ] || DEX_PATH="/data/local/tmp/agent_vd.dex"
[ -f "$VD_ENV" ] || VD_ENV="/data/local/tmp/vd_env.sh"

# ---- 载入跨厂商环境解析器 -----------------------------------------------
if [ -f "$VD_ENV" ]; then
    . "$VD_ENV"
else
    echo "[run_daemon] 致命错误: 缺少 $VD_ENV，无法构建 BOOTCLASSPATH" >&2
    exit 1
fi

# ---- 物理屏参数自动探测 --------------------------------------------------
WIDTH=1080
HEIGHT=2400
DPI=420

# 优先使用 Override size（用户可能改过分辨率），退化到 Physical size
WM_SIZE=$(/system/bin/wm size 2>/dev/null)
PHYS_SIZE=$(echo "$WM_SIZE" | grep -i "Override size:" | head -n 1)
if [ -z "$PHYS_SIZE" ]; then
    PHYS_SIZE=$(echo "$WM_SIZE" | grep -i "Physical size:" | head -n 1)
fi
if [ -n "$PHYS_SIZE" ]; then
    W=$(echo "$PHYS_SIZE" | awk '{print $NF}' | cut -d'x' -f1)
    H=$(echo "$PHYS_SIZE" | awk '{print $NF}' | cut -d'x' -f2)
    case "$W" in ''|*[!0-9]*) W="" ;; esac
    case "$H" in ''|*[!0-9]*) H="" ;; esac
    if [ -n "$W" ] && [ -n "$H" ] && [ "$W" -ge 320 ] && [ "$H" -ge 320 ]; then
        WIDTH="$W"
        HEIGHT="$H"
    fi
fi

WM_DENSITY=$(/system/bin/wm density 2>/dev/null)
PHYS_DPI=$(echo "$WM_DENSITY" | grep -i "Override density:" | head -n 1)
if [ -z "$PHYS_DPI" ]; then
    PHYS_DPI=$(echo "$WM_DENSITY" | grep -i "Physical density:" | head -n 1)
fi
if [ -n "$PHYS_DPI" ]; then
    D=$(echo "$PHYS_DPI" | awk '{print $NF}' | tr -dc '0-9')
    if [ -n "$D" ] && [ "$D" -ge 72 ] && [ "$D" -le 1000 ]; then
        DPI="$D"
    fi
fi

# 允许 CLI 参数覆盖
if [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ]; then
    WIDTH="$1"
    HEIGHT="$2"
    DPI="$3"
fi

echo "[run_daemon] 副屏规格: ${WIDTH}x${HEIGHT} @ ${DPI} DPI (物理屏自动匹配)"

# ---- 构建 app_process 运行环境 -------------------------------------------
if ! vd_export_app_process_env; then
    echo "[run_daemon] 致命错误: BOOTCLASSPATH 解析失败" >&2
    exit 1
fi
echo "[run_daemon] BOOTCLASSPATH 已解析 ($(echo "$BOOTCLASSPATH" | tr ':' '\n' | grep -c .) 项)"

export CLASSPATH="$DEX_PATH"
exec /system/bin/app_process /system/bin com.agent.DaemonMain "$WIDTH" "$HEIGHT" "$DPI"
