#!/usr/bin/env bash
# =====================================================================
# 编译 helper-apk 模块 (纯 Linux 环境优化版)
# =====================================================================

set -euo pipefail

# ==============================
# 📋 可配置变量 (根据需要修改)
# ==============================

# Android SDK 版本配置
MIN_SDK_VERSION=26
# TARGET_SDK_VERSION 将自动从已安装的 platform 中提取，无需手动设置

# Java/Kotlin 编译目标版本
JVM_TARGET=11

# APK 版本信息 (可通过环境变量 VC/VN 覆盖)
VERSION_CODE="${VC:-10000}"
VERSION_NAME="${VN:-1.0.0}"

# Maven 仓库配置
MAVEN_REPO="https://repo1.maven.org/maven2"
COR_GROUP="org.jetbrains.kotlinx"
COR_ANDROID_ARTIFACT="kotlinx-coroutines-android"

# 签名配置
KS_ALIAS="suclash"
KS_PASS="suclash123"
APK_OUTPUT_NAME="MihomoControl.apk"

# ==============================
# 1. 环境初始化与检查
# ==============================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK_DIR="$ROOT/helper-apk"
TOOLS_DIR="${GITHUB_WORKSPACE:-$(pwd)}/tmp"

# 检查环境变量 (由 get-tools.sh 注入)
if [ -z "$JAVA_HOME" ] || [ -z "$platform_android_jar" ]; then
    echo "❌ 缺少 JAVA_HOME 或 platform_android_jar 环境变量。"
    echo "💡 请先运行: bash tools/get-tools.sh"
    exit 1
fi

# 检查核心构建命令
for cmd in java javac jar kotlinc aapt2 zipalign apksigner; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ 缺少构建命令: $cmd"
        echo "💡 请确保已运行 tools/get-tools.sh 且环境变量已生效。"
        exit 1
    fi
done

# 检查源码目录
if [ ! -d "$APK_DIR/src" ] || [ ! -f "$APK_DIR/AndroidManifest.xml" ]; then
    echo "❌ 未找到 helper-apk 源码目录或 AndroidManifest.xml"
    exit 1
fi

# 自动从 platform_android_jar 路径中提取 Target SDK 版本
# 例如: ~/Android/Sdk/platforms/android-35/android.jar -> 35
TARGET_SDK_VERSION=$(echo "$platform_android_jar" | grep -oP 'android-\K[0-9]+')
if [ -z "$TARGET_SDK_VERSION" ]; then
    echo "⚠️ 无法自动提取 Target SDK 版本，使用默认值 34"
    TARGET_SDK_VERSION=34
fi

echo "📋 构建配置:"
echo "   Min SDK: $MIN_SDK_VERSION"
echo "   Target SDK: $TARGET_SDK_VERSION"
echo "   JVM Target: $JVM_TARGET"
echo "   Version: $VERSION_NAME ($VERSION_CODE)"

# 获取 JDK 版本，配置必要的 JVM 参数 (兼容 JDK 24+)
JAVA_OPTS=""
JAVA_V=$(java -version 2>&1 | head -1)
if [[ "$JAVA_V" =~ \"([0-9]+) ]]; then
    if [ "${BASH_REMATCH[1]}" -ge 24 ]; then
        JAVA_OPTS="--sun-misc-unsafe-memory-access=allow --enable-native-access=ALL-UNNAMED"
    fi
fi
export JAVA_OPTS

# ==============================
# 2. 依赖库准备 (优先使用 kotlinc 自带，缺失时自动下载)
# ==============================
echo "📦 检查 Kotlin 依赖库..."
LIBS_DIR="$APK_DIR/libs"
mkdir -p "$LIBS_DIR"

KOTLIN_LIB_DIR="$TOOLS_DIR/kotlinc/lib"

# 查找 kotlinc 自带的 stdlib：必须是含 .class 的主 jar。
# 不能用 find|head 模糊匹配，否则可能误选到 -sources/-jdk7/-jdk8 等薄 jar，
# 导致 R8 报 "Missing class kotlin.text.*" 并回退 d8。
KOTLIN_STDLIB="$KOTLIN_LIB_DIR/kotlin-stdlib.jar"
if [ ! -f "$KOTLIN_STDLIB" ]; then
    echo "❌ 未找到 kotlin-stdlib.jar，请检查 kotlinc 安装。"
    exit 1
fi

# 智能查找或下载依赖：优先 kotlinc/lib -> 其次 libs/ 缓存 -> 最后 Maven 下载
find_or_download() {
    local artifact=$1
    local version=$2
    local filename="${artifact}-${version}.jar"

    # 1. 优先在 kotlinc/lib 中查找 (编译器自带)
    local found
    found=$(find "$KOTLIN_LIB_DIR" -name "${artifact}*.jar" 2>/dev/null | head -n 1)

    if [ -n "$found" ]; then
        echo "✅ 使用 kotlinc 自带: $(basename "$found")" >&2
        echo "$found"
        return 0
    fi

    # 2. 在 libs 目录中查找本地缓存
    local dest="$LIBS_DIR/$filename"
    if [ -f "$dest" ]; then
        echo "✅ 使用本地缓存: $filename" >&2
        echo "$dest"
        return 0
    fi

    # 3. 从 Maven Central 下载
    local url="$MAVEN_REPO/${COR_GROUP//.//}/$artifact/$version/$filename"
    echo "⬇️ 正在下载: $filename" >&2
    curl -fSL "$url" -o "$dest"
    echo "$dest"
}

# 自动获取 Coroutines 最新版本 (失败时回退到默认值)
get_latest_coroutines_version() {
    local default_version="1.11.0"
    local latest
    latest=$(curl -s --max-time 5 \
        "https://repo1.maven.org/maven2/org/jetbrains/kotlinx/kotlinx-coroutines-android/maven-metadata.xml" |
        grep -oP '<latest>\K[^<]+' 2>/dev/null)

    if [ -n "$latest" ]; then
        echo "$latest"
    else
        echo "$default_version"
    fi
}

COROUTINES_VERSION="${COROUTINES_VERSION:-$(get_latest_coroutines_version)}"
echo "使用 Coroutines 版本: $COROUTINES_VERSION"

COR_ANDROID=$(find_or_download "$COR_ANDROID_ARTIFACT" "$COROUTINES_VERSION")

# kotlinx-coroutines-core 是 coroutines-android 的传递依赖，R8/D8 打包必须显式引入
COR_CORE_ARTIFACT="kotlinx-coroutines-core"
COR_CORE=$(find_or_download "$COR_CORE_ARTIFACT" "$COROUTINES_VERSION")

# 查找 d8.jar (用于 R8/D8 混淆与 Dex 化)
D8_JAR=$(find "$HOME/Android/Sdk" -name "d8.jar" 2>/dev/null | head -n 1)
if [ -z "$D8_JAR" ]; then
    echo "❌ 未找到 d8.jar，请检查 Android Build Tools 安装。"
    exit 1
fi

# ==============================
# 3. 构建目录准备
# ==============================
BUILD_DIR="$APK_DIR/build"
# 最终 APK 与 mihomo / suclash_helper 统一输出到仓库根 build/，供 package-module.sh 打包
OUTPUT_DIR="$ROOT/build"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"/{gen,obj,kclasses,dex}
mkdir -p "$OUTPUT_DIR"

cd "$APK_DIR"

# ==============================
# 4. 资源编译与链接
# ==============================
echo ">> aapt2 compile"
aapt2 compile --dir res -o build/res.zip

echo ">> aapt2 link"
aapt2 link -o build/base.apk -I "$platform_android_jar" \
    --manifest AndroidManifest.xml \
    --java build/gen \
    --min-sdk-version "$MIN_SDK_VERSION" \
    --target-sdk-version "$TARGET_SDK_VERSION" \
    --version-code "$VERSION_CODE" \
    --version-name "$VERSION_NAME" \
    --auto-add-overlay build/res.zip

# ==============================
# 5. Kotlin 与 Java 编译
# ==============================
echo ">> kotlinc"
KT_SRC=$(find src -name '*.kt')
R_SRC=$(find build/gen -name '*.java')

kotlinc -jvm-target "$JVM_TARGET" -nowarn \
    -classpath "$platform_android_jar:$COR_CORE:$COR_ANDROID" \
    -d build/kclasses $KT_SRC $R_SRC

echo ">> javac (R.java)"
find build/gen -name '*.java' >build/sources.txt
javac --release "$JVM_TARGET" -encoding UTF-8 -classpath "$platform_android_jar" -d build/obj @build/sources.txt

# 打包 Kotlin 字节码
jar -cf build/kclasses.jar -C build/kclasses .

# ==============================
# 6. R8/D8 混淆与 Dex 化
# ==============================
echo ">> R8 (裁剪与混淆)"
cat >build/r8.pro <<'EOF'
# 保留运行时反射所需的注解（addJavascriptInterface 依赖 @JavascriptInterface 反射查找方法）
-keepattributes *Annotation*
# Manifest 组件与 WebView JS 桥需反射可达
-keep class io.github.suclash.control.** { *; }
# 显式 keep 所有 @JavascriptInterface 注解方法（防 R8 剥离注解导致桥方法不暴露给 JS）
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-dontwarn kotlinx.coroutines.**
-dontwarn java.lang.invoke.**
-dontwarn org.jetbrains.annotations.**
EOF

# 定义 R8/D8 调用函数
run_r8() { java $JAVA_OPTS -cp "$D8_JAR" com.android.tools.r8.R8 "$@"; }
run_d8() { java $JAVA_OPTS -cp "$D8_JAR" com.android.tools.r8.D8 "$@"; }

if run_r8 \
    --release --min-api "$MIN_SDK_VERSION" --lib "$platform_android_jar" \
    --pg-conf build/r8.pro --pg-map-output build/map.txt \
    --output build/dex \
    build/kclasses.jar "$KOTLIN_STDLIB" "$COR_CORE" "$COR_ANDROID" \
    $(find build/obj -name '*.class') 2>build/r8.log; then
    echo ">> R8 完成"
else
    echo "!! R8 失败，回退 d8（APK 体积会偏大）:"
    tail -5 build/r8.log || true
    run_d8 \
        --release --min-api "$MIN_SDK_VERSION" --lib "$platform_android_jar" \
        --output build/dex \
        build/kclasses.jar "$KOTLIN_STDLIB" "$COR_CORE" "$COR_ANDROID" \
        $(find build/obj -name '*.class')
fi

# ==============================
# 7. 打包、对齐与签名
# ==============================
echo ">> package"
cp build/base.apk build/app.apk
(cd build/dex && jar -uf ../app.apk classes.dex)

echo ">> zipalign"
zipalign -f 4 build/app.apk build/aligned.apk

echo ">> apksigner"
KS="$APK_DIR/suclash.keystore"
[ -f "$KS" ] || KS="$TOOLS_DIR/suclash.keystore"
KS_OUT="$OUTPUT_DIR/$APK_OUTPUT_NAME"

if [ ! -f "$KS" ]; then
    echo "❌ 未找到签名密钥: $KS"
    exit 1
fi

# apksigner 是 JVM 启动器 shell 脚本，不读取 JAVA_OPTS；这里用 JDK_JAVA_OPTIONS 注入，
# 消除 JDK 24+ 下 conscrypt 的 "restricted method ... loadLibrary" 警告。
export JDK_JAVA_OPTIONS="$JAVA_OPTS"
apksigner sign --ks "$KS" --ks-key-alias "$KS_ALIAS" \
    --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
    --out "$KS_OUT" build/aligned.apk

apksigner verify --print-certs "$KS_OUT" | head -3
unset JDK_JAVA_OPTIONS

echo "🎉 构建完成: $KS_OUT"
