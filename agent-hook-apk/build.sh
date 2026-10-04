#!/bin/bash
# =============================================================================
# build.sh — 构建 Agent Mobile Use Hook APK
#
# 相比原版的变化：
#   * 不再硬编码 /usr/lib/android-sdk 路径，改为自动探测（Ubuntu 的 android-sdk
#     包在不同版本里布局不同，原版 build.sh 在多数环境直接找不到 dx / android.jar）
#   * dx 已废弃（Android Gradle Plugin 7+ 移除），改用 r8/d8 生成 dex
#   * 资源编译改用 aapt2（compile + link）。Debian 自带的 aapt 版本过老，
#     读不了 Android 14+ android.jar 的 resources.arsc，会报
#     "No resource identifier found for attribute 'xxx'"
#   * Xposed API 使用编译期 stub（XPOSED_STUB_DIR），运行时由 LSPosed 注入真实实现
#
# 依赖（可由环境变量覆盖）：
#   ANDROID_JAR      android.jar（含 android.* 与隐藏 API），默认自动探测
#   AAPT2            aapt2 可执行文件或包装脚本，默认自动探测
#   XPOSED_STUB_DIR  Xposed API stub 源码目录，默认 /opt/xposed-stub/src
#   D8_JAR           r8.jar（内含 d8），默认 /opt/android-tools/r8b.jar
#   KEYSTORE         签名密钥库，默认自动生成 /root/debug.keystore
#   MIN_SDK/TARGET_SDK  默认 26 / 37
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MIN_SDK="${MIN_SDK:-26}"
TARGET_SDK="${TARGET_SDK:-37}"

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

# ---- 探测 aapt2 -----------------------------------------------------------
if [ -z "$AAPT2" ]; then
    for c in /opt/android-tools/aapt2-run.sh /opt/android-tools/aapt2; do
        [ -x "$c" ] && AAPT2="$c" && break
    done
fi
if [ -z "$AAPT2" ]; then
    command -v aapt2 >/dev/null 2>&1 && AAPT2="aapt2"
fi
if [ -z "$AAPT2" ]; then
    echo "[build] 错误: 找不到 aapt2" >&2
    exit 1
fi
echo "[build] aapt2      = $AAPT2"

# ---- 探测 Xposed stub -----------------------------------------------------
XPOSED_STUB_DIR="${XPOSED_STUB_DIR:-/opt/xposed-stub/src}"
if [ ! -d "$XPOSED_STUB_DIR" ]; then
    echo "[build] 错误: 找不到 Xposed API stub 目录: $XPOSED_STUB_DIR" >&2
    exit 1
fi

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

for t in zipalign apksigner; do
    command -v $t >/dev/null 2>&1 || { echo "[build] 错误: 缺少 $t" >&2; exit 1; }
done

rm -rf build
mkdir -p build/gen build/classes build/apk build/dexout

echo "[build] 1/6 编译资源 (aapt2 compile)..."
"$AAPT2" compile --dir res -o build/apk/res.zip

echo "[build] 2/6 链接资源并生成 R.java (aapt2 link)..."
"$AAPT2" link \
    -o build/apk/resources.apk \
    -I "$ANDROID_JAR" \
    --manifest AndroidManifest.xml \
    --java build/gen \
    --min-sdk-version "$MIN_SDK" \
    --target-sdk-version "$TARGET_SDK" \
    --auto-add-overlay \
    build/apk/res.zip

echo "[build] 3/6 编译 Java 源码..."
# stub 与业务源码一起编译；stub 只提供符号，不会进入最终 dex
javac -proc:none -nowarn -source 8 -target 8 \
    -bootclasspath "$ANDROID_JAR" \
    -cp "$ANDROID_JAR" \
    $(find src build/gen "$XPOSED_STUB_DIR" -name "*.java") \
    -d build/classes

echo "[build] 4/6 生成 classes.dex (d8)..."
# 只把业务类打进 dex：stub 的 de.robv.* 必须排除，否则会遮蔽 LSPosed 运行时的真实实现
find build/classes -name "*.class" ! -path "*/de/robv/*" > build/dex-inputs.txt
$D8_CMD --min-api "$MIN_SDK" --output build/dexout $(cat build/dex-inputs.txt)

echo "[build] 5/6 组装 APK..."
cp build/apk/resources.apk build/apk/unsigned.apk
# aapt2 link 的产物是 zip；用 Python 直接追加条目，避免 aapt add 额外重压缩
python3 - "$PWD" <<'PY'
import sys, zipfile, os
base = sys.argv[1]
apk = os.path.join(base, 'build/apk/unsigned.apk')
add = [
    (os.path.join(base, 'build/dexout/classes.dex'), 'classes.dex'),
    (os.path.join(base, 'assets/xposed_init'), 'assets/xposed_init'),
]
with zipfile.ZipFile(apk, 'a', zipfile.ZIP_DEFLATED) as z:
    existing = set(z.namelist())
    for path, arc in add:
        if not os.path.exists(path):
            print(f"  ! 缺少 {path}")
            continue
        if arc in existing:
            print(f"  - {arc} 已存在，跳过")
            continue
        z.write(path, arc)
        print(f"  + {arc}")
PY
zipalign -p -f 4 build/apk/unsigned.apk build/apk/aligned.apk

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

echo "[build] 完成: $SCRIPT_DIR/build/agent_hook.apk"
ls -lh build/agent_hook.apk
echo "[build] 校验:"
apksigner verify --print-certs build/agent_hook.apk 2>&1 | head -4
python3 -c "
import zipfile
z=zipfile.ZipFile('$SCRIPT_DIR/build/agent_hook.apk')
ns=z.namelist()
print('  APK 条目:', [n for n in ns if not n.startswith('META-INF')][:8])
print('  含 classes.dex:', 'classes.dex' in ns)
print('  含 xposed_init:', 'assets/xposed_init' in ns)
"
