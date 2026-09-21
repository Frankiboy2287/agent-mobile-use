#!/bin/bash
# =============================================================================
# build.sh — 构建 Agent Mobile Use Hook APK
#
# 相比原版的变化：
#   * 不再硬编码 /usr/lib/android-sdk 路径，改为自动探测（Ubuntu 的 android-sdk
#     包在不同版本里布局不同，原版 build.sh 在多数环境直接找不到 dx / android.jar）
#   * dx 已废弃（Android Gradle Plugin 7+ 移除），改用 r8/d8 生成 dex
#   * Xposed API 使用编译期 stub（XPOSED_STUB_DIR），运行时由 LSPosed 注入真实实现
#
# 依赖（可由环境变量覆盖）：
#   ANDROID_JAR      android.jar（含 android.* 与隐藏 API），默认自动探测
#   XPOSED_STUB_DIR  Xposed API stub 源码目录，默认 /opt/xposed-stub/src
#   D8_JAR           r8.jar（内含 d8），默认 /opt/android-tools/r8b.jar
#   KEYSTORE         签名密钥库，默认自动生成 /root/debug.keystore
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

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

# ---- 探测 Xposed stub -----------------------------------------------------
XPOSED_STUB_DIR="${XPOSED_STUB_DIR:-/opt/xposed-stub/src}"
if [ ! -d "$XPOSED_STUB_DIR" ]; then
    echo "[build] 错误: 找不到 Xposed API stub 目录: $XPOSED_STUB_DIR" >&2
    exit 1
fi
echo "[build] xposed stub = $XPOSED_STUB_DIR"

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

# ---- 探测打包/签名工具 ----------------------------------------------------
for t in aapt zipalign apksigner; do
    command -v $t >/dev/null 2>&1 || { echo "[build] 错误: 缺少 $t" >&2; exit 1; }
done

rm -rf build
mkdir -p build/gen build/classes build/apk

echo "[build] 1/6 生成 R.java 与资源包..."
aapt package -f -m -0 arsc \
    -S res \
    -J build/gen \
    -M AndroidManifest.xml \
    -I "$ANDROID_JAR" \
    -F build/apk/unaligned.apk

echo "[build] 2/6 编译 Java 源码..."
# stub 与业务源码一起编译；stub 只提供符号，不会进入最终 dex
javac -proc:none -nowarn -source 8 -target 8 \
    -bootclasspath "$ANDROID_JAR" \
    -cp "$ANDROID_JAR" \
    $(find src build/gen "$XPOSED_STUB_DIR" -name "*.java") \
    -d build/classes

echo "[build] 3/6 生成 classes.dex (d8)..."
# 只把业务类打进 dex：stub 的 de.robv.* 必须排除，否则会遮蔽 LSPosed 运行时的真实实现
find build/classes -name "*.class" ! -path "*/de/robv/*" > build/dex-inputs.txt
mkdir -p build/dexout
$D8_CMD --min-api 26 --output build/dexout $(cat build/dex-inputs.txt)
cp build/dexout/classes.dex build/classes.dex

echo "[build] 4/6 打包 APK..."
cd build
aapt add apk/unaligned.apk classes.dex >/dev/null
cd "$SCRIPT_DIR"
aapt add build/apk/unaligned.apk assets/xposed_init >/dev/null

echo "[build] 5/6 zipalign..."
zipalign -p -f 4 build/apk/unaligned.apk build/apk/aligned.apk

echo "[build] 6/6 签名..."
KEYSTORE="${KEYSTORE:-/root/debug.keystore}"
if [ ! -f "$KEYSTORE" ]; then
    keytool -genkeypair -v -keystore "$KEYSTORE" \
        -storepass android -alias androiddebugkey -keypass android \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
fi
apksigner sign --ks "$KEYSTORE" \
    --ks-pass pass:android --ks-key-alias androiddebugkey \
    --key-pass pass:android \
    --out build/agent_hook.apk \
    build/apk/aligned.apk

echo "[build] 完成: $(pwd)/build/agent_hook.apk"
ls -lh build/agent_hook.apk
