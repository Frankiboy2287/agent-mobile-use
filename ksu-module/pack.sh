#!/bin/bash
# =============================================================================
# pack.sh — 组装 KernelSU / APatch(FolkPatch) / Magisk 模块刷机包
#
# 相比原版的改动：
#   * 硬编码的 /storage/emulated/0/Download 改为可选：该路径只在设备本机存在，
#     在容器 / CI 里直接 cp 会失败中断（原版 set -e 下会以非零码退出）
#   * 从 agent-hook-apk/build 同步重新编译的 agent_hook.apk（原版不刷新，
#     导致模块里打包的永远是旧的 Hook APK）
#   * 缺少 Go 二进制时给出明确提示而不是静默拷贝失败
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "[ksu-pack] 刷新已编译产物..."

# 1. Go 网关
GO_BIN="$WORKSPACE/vd-server-go/vd_server"
if [ -f "$GO_BIN" ]; then
    cp "$GO_BIN" "$SCRIPT_DIR/bin/vd_server"
    echo "  + bin/vd_server"
else
    echo "  ! 未找到 vd-server-go/vd_server（如需更新请在 vd-server-go/ 执行 ./build.sh）"
    [ -f "$SCRIPT_DIR/bin/vd_server" ] || { echo "  ! 模块内也没有现成二进制，打包中止" >&2; exit 1; }
fi

# 2. Java 工具 dex
for d in agent_tools.dex agent_vd.dex; do
    SRC="$WORKSPACE/vd-tool-java/bin/$d"
    if [ -f "$SRC" ]; then
        cp "$SRC" "$SCRIPT_DIR/bin/$d"
        echo "  + bin/$d"
    else
        echo "  ! 缺少 $SRC" >&2
        exit 1
    fi
done

# 3. Hook APK（重新编译后需同步，否则模块里永远是旧版本）
HOOK_APK="$WORKSPACE/agent-hook-apk/build/agent_hook.apk"
if [ -f "$HOOK_APK" ]; then
    cp "$HOOK_APK" "$SCRIPT_DIR/apk/agent_hook.apk"
    echo "  + apk/agent_hook.apk ($(stat -c %s "$HOOK_APK") bytes)"
elif [ -f "$SCRIPT_DIR/apk/agent_hook.apk" ]; then
    echo "  ~ apk/agent_hook.apk 沿用现有版本（如需重建请执行 agent-hook-apk/build.sh）"
else
    echo "  ! 缺少 Hook APK，打包中止" >&2
    exit 1
fi

# 4. 打 zip
cd "$SCRIPT_DIR"
ZIP="$WORKSPACE/agent-mobile-use-ksu.zip"
echo "[ksu-pack] 正在打包 agent-mobile-use-ksu.zip..."
rm -f "$ZIP"
zip -r -q "$ZIP" . -x "*.git*" -x "pack.sh"
echo "  -> $ZIP"

# 5. 可选：复制到设备下载目录（仅在设备本机存在时）
DL="/storage/emulated/0/Download"
if [ -d "$DL" ]; then
    cp "$ZIP" "$DL/agent-mobile-use-ksu.zip" && echo "  -> $DL/agent-mobile-use-ksu.zip"
else
    echo "  (跳过复制到 Download：本机无 $DL)"
fi

echo "[ksu-pack] 完成:"
ls -lh "$ZIP"
