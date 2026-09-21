#!/bin/bash
# =============================================================================
# build.sh — 编译 vd 工具链（agent_tools.dex / agent_vd.dex）
#
# 相比原版的改动：
#   * 不再硬编码 /usr/lib/android-sdk 路径（Ubuntu 各版本布局不同，原版多数环境
#     直接找不到 android.jar 与 dx），改为自动探测
#   * dx 已废弃（Android Gradle Plugin 7+ 移除），改用 r8/d8
#   * 补上 ImePolicyHelper.java —— DaemonMain 依赖它，原版脚本不编译该文件会直接失败
#   * 用 -bootclasspath 指定 android.jar：在 JDK 17 下只用 -cp 会让 javac 拿 JDK 自带的
#     java.* 去解析，与 Android 的 core 库语义不一致
#
# 依赖（可由环境变量覆盖）：
#   ANDROID_JAR  android.jar（含 android.* 与隐藏 API），默认自动探测
#   D8_JAR       r8.jar（内含 d8），默认 /opt/android-tools/r8b.jar
#   MIN_SDK      默认 26
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MIN_SDK="${MIN_SDK:-26}"

# ---- 探测 android.jar ------------------------------------------------------
if [ -z "$ANDROID_JAR" ]; then
    for c in \
        /opt/android-tools/android-37.jar \
        /opt/android-tools/android-36.jar \
        /usr/lib/android-sdk/platforms/android-37/android.jar \
        /usr/lib/android-sdk/platforms/android-36/android.jar \
        /usr/lib/android-sdk/platforms/android-35/android.jar
    do
        [ -f "$c" ] && ANDROID_JAR="$c" && break
    done
fi
if [ ! -f "$ANDROID_JAR" ]; then
    echo "[build] 错误: 找不到 android.jar，请设置 ANDROID_JAR 环境变量" >&2
    exit 1
fi
echo "[build] android.jar = $ANDROID_JAR"

# ---- 探测 d8 --------------------------------------------------------------
D8_JAR="${D8_JAR:-/opt/android-tools/r8b.jar}"
D8_CMD=""
if [ -f "$D8_JAR" ]; then
    D8_CMD="java -cp $D8_JAR com.android.tools.r8.D8"
elif command -v d8 >/dev/null 2>&1; then
    D8_CMD="d8"
fi
if [ -z "$D8_CMD" ]; then
    echo "[build] 错误: 找不到 d8（既没有 $D8_JAR 也没有 PATH 中的 d8）" >&2
    exit 1
fi
echo "[build] d8          = $D8_CMD"

rm -rf bin/classes
mkdir -p bin/classes

echo "[build] 1/3 编译 Java 源码..."
javac -proc:none -nowarn -source 8 -target 8 \
    -bootclasspath "$ANDROID_JAR" \
    -cp "$ANDROID_JAR" \
    src/com/agent/ToolMain.java \
    src/com/agent/DaemonMain.java \
    src/com/agent/ImePolicyHelper.java \
    -d bin/classes

echo "[build] 2/3 生成 agent_tools.dex..."
mkdir -p bin/dexout_tools
$D8_CMD --min-api "$MIN_SDK" --output bin/dexout_tools \
    $(find bin/classes/com/agent -name 'ToolMain*.class')
cp bin/dexout_tools/classes.dex bin/agent_tools.dex

echo "[build] 3/3 生成 agent_vd.dex..."
mkdir -p bin/dexout_vd
$D8_CMD --min-api "$MIN_SDK" --output bin/dexout_vd \
    $(find bin/classes/com/agent -name 'DaemonMain*.class' -o -name 'ImePolicyHelper*.class')
cp bin/dexout_vd/classes.dex bin/agent_vd.dex

rm -rf bin/dexout_tools bin/dexout_vd

echo "[build] 完成:"
ls -lh bin/agent_tools.dex bin/agent_vd.dex
