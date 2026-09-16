#!/usr/bin/env bash
# =====================================================================
# 警告：不要在开发电脑上随意运行此脚本！
# 此脚本用于 CI/CD 环境及本地开发环境的自动化依赖配置。
# 它会自动下载并安装构建 helper-apk 所需的工具链。
# =====================================================================

# 遇到任何未处理的错误立即退出
set -e

# ==============================
# 0. 架构检查 (仅限 amd64)
# ==============================
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    echo "❌ 此脚本仅支持在 amd64 (x86_64) 架构上运行。当前检测到的架构: $ARCH"
    exit 1
fi

# ==============================
# 辅助函数：环境检测与变量注入
# ==============================
is_ci() {
    [ -n "$GITHUB_ACTIONS" ] || [ -n "$CI" ]
}

add_to_env() {
    local key=$1 value=$2
    export "$key=$value"
    if is_ci && [ -n "$GITHUB_ENV" ]; then
        echo "$key=$value" >>"$GITHUB_ENV"
    fi
    echo "export $key=\"$value\"" >>"$ENV_FILE"
}

add_to_path() {
    local dir=$1
    export PATH="$dir:$PATH"
    if is_ci && [ -n "$GITHUB_PATH" ]; then
        echo "$dir" >>"$GITHUB_PATH"
    fi
    echo "export PATH=\"$dir:\$PATH\"" >>"$ENV_FILE"
}

# ==============================
# 1. 基础依赖检查与自动安装
# ==============================
REQUIRED_CMDS=(curl tar unzip jq awk grep sort)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "⚠️ 缺少必要工具: $cmd"
        if is_ci; then
            echo "❌ CI 环境缺少基础工具，请检查 Runner 镜像配置。"
            exit 1
        else
            echo "🔧 本地环境缺少 $cmd，尝试使用 apt 自动安装 (需要 sudo 权限)..."
            sudo apt update && sudo apt install -y "$cmd" || {
                echo "❌ 自动安装失败，请手动执行: sudo apt install $cmd"
                exit 1
            }
        fi
    fi
done

# ==============================
# 2. 目录初始化与缓存文件准备
# ==============================
TOOLS_DIR="${GITHUB_WORKSPACE:-$(pwd)}/tmp"
mkdir -p "$TOOLS_DIR"
cd "$TOOLS_DIR"

# 生成本地环境专用的 .env 文件
ENV_FILE="$TOOLS_DIR/.env"
echo "# =========================================" >"$ENV_FILE"
echo "# 自动生成的环境变量文件" >>"$ENV_FILE"
echo "# 本地调试请在终端执行: source $ENV_FILE" >>"$ENV_FILE"
echo "# =========================================" >>"$ENV_FILE"

# ==============================
# 3. 安装 Azul Zulu JDK
# ==============================
java_version="25"
echo "📦 [1/5] 正在处理 Azul Zulu JDK $java_version..."

JDK_DIR=$(ls -d zulu${java_version}* 2>/dev/null | head -n 1)
if [ -z "$JDK_DIR" ] || [ ! -d "$JDK_DIR" ]; then
    echo "⬇️ 未检测到缓存，正在下载 JDK..."
    JDK_URL=$(curl -s -X GET "https://api.azul.com/metadata/v1/zulu/packages/?java_version=${java_version}&os=linux-glibc&arch=x64&archive_type=tar.gz&java_package_type=jdk&javafx_bundled=false&crac_supported=false&crs_supported=false&support_term=lts&latest=true&release_status=ga&availability_types=ca&certifications=tck&page=1&page_size=100" -H "accept: application/json" | jq -r '.[0].download_url')

    curl -fSL "$JDK_URL" -o zulu.tar.gz
    tar -xzf zulu.tar.gz
    rm zulu.tar.gz
    JDK_DIR=$(ls -d zulu${java_version}* 2>/dev/null | head -n 1)
else
    echo "✅ 发现已缓存的 JDK 目录: $JDK_DIR"
fi

JDK_PATH="$TOOLS_DIR/$JDK_DIR"
add_to_env "JAVA_HOME" "$JDK_PATH"
add_to_path "$JDK_PATH/bin"

java -version
echo "✅ JDK $java_version 配置完毕"

# ==============================
# 4. 安装 Android SDK (使用稳定的 sdkmanager)
# ==============================
echo "📦 [2/5] 正在处理 Android SDK (sdkmanager)..."

# 检查 sdkmanager 是否可用，不可用则下载 Android Command-line Tools
if ! command -v sdkmanager &>/dev/null; then
    echo "⬇️ 未检测到 sdkmanager，正在下载 Android Command-line Tools..."
    # 下载官方稳定的 commandlinetools
    curl -fSL "https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip" -o cmd-tools.zip

    # 按照 Google 官方要求，必须解压到 cmdline-tools/latest 目录
    mkdir -p ~/Android/Sdk/cmdline-tools
    unzip -q cmd-tools.zip -d ~/Android/Sdk/cmdline-tools/
    mv ~/Android/Sdk/cmdline-tools/cmdline-tools ~/Android/Sdk/cmdline-tools/latest
    rm cmd-tools.zip
fi

# 将 sdkmanager 加入 PATH
CMD_TOOLS_BIN="$HOME/Android/Sdk/cmdline-tools/latest/bin"
add_to_path "$CMD_TOOLS_BIN"

# 🌟 核心：在 CI 中必须使用 yes | 自动同意所有 License，否则 sdkmanager 会卡死
echo "正在自动同意 Android SDK Licenses..."
yes | sdkmanager --licenses >/dev/null 2>&1 || true

# --- 安装 Build Tools ---
# 从 sdkmanager --list 提取最新的 build-tools 版本号
BUILD_TOOLS_VER=$(sdkmanager --list | grep "build-tools;" | awk '{print $1}' | sort -V | tail -n 1)
echo "正在安装 Build Tools: $BUILD_TOOLS_VER"
sdkmanager "$BUILD_TOOLS_VER"

# 获取 build-tools 的绝对路径并配置到 PATH
BUILD_TOOLS_LATEST=$(ls -d ~/Android/Sdk/build-tools/* 2>/dev/null | sort -V | tail -n 1)
add_to_path "$BUILD_TOOLS_LATEST"
which aapt2
echo "✅ Build Tools 配置完毕: $BUILD_TOOLS_LATEST"

# --- 安装 Platform (android.jar) ---
# 从 sdkmanager --list 提取最新的 platforms 版本号
LATEST_STABLE=$(sdkmanager --list | grep "platforms;android-" | grep -v "ext" | grep -viE "canary|preview|rc|beta|alpha" | awk '{print $1}' | sort -V | tail -n 1)
echo "检测到的platforms最新稳定版为: $LATEST_STABLE"
sdkmanager "$LATEST_STABLE"

# 将 platforms;android-35 格式转换为路径格式 platforms/android-35
PLATFORM_DIR=$(echo "$LATEST_STABLE" | tr ';' '/')
PLATFORM_ANDROID_JAR=$(ls -d ~/Android/Sdk/$PLATFORM_DIR/android.jar 2>/dev/null | head -n 1)
add_to_env "platform_android_jar" "$PLATFORM_ANDROID_JAR"
echo "✅ Platform 配置完毕: $LATEST_STABLE"

# ==============================
# 5. 安装 Kotlin 编译器
# ==============================
echo "📦 [3/5] 正在处理 Kotlin 编译器..."

# 固定 Kotlin 版本：Android build-tools 内置的 R8 最高只支持 Kotlin metadata 2.3.0，
# 若用最新的 2.4.x（metadata 2.4.0）会触发 R8 解析 Kotlin metadata 失败并回退 d8。
# 故固定到 2.3.x 最新版，保证 R8 正常裁剪混淆。
KOTLIN_VERSION="2.3.21"
if [ ! -d "kotlinc" ]; then
    echo "⬇️ 未检测到缓存，正在下载 Kotlin 编译器 $KOTLIN_VERSION..."
    KOTLIN_URL="https://github.com/JetBrains/kotlin/releases/download/v${KOTLIN_VERSION}/kotlin-compiler-${KOTLIN_VERSION}.zip"

    curl -fSL "$KOTLIN_URL" -o kotlin.zip
    unzip -q kotlin.zip
    rm kotlin.zip
else
    echo "✅ 发现已缓存的 kotlinc 目录"
fi

KOTLIN_BIN_PATH="$TOOLS_DIR/kotlinc/bin"
add_to_path "$KOTLIN_BIN_PATH"
echo "✅ Kotlin 编译器配置完毕"

# ==============================
# 6. 安装 Go 编译器
# ==============================
echo "📦 [4/5] 正在处理 Go 编译器..."

if [ ! -d "go" ]; then
    echo "⬇️ 未检测到缓存，正在获取最新稳定版 Go..."
    GO_VERSION=$(curl -sL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version')

    GO_TARBALL="${GO_VERSION}.linux-amd64.tar.gz"
    GO_URL="https://go.dev/dl/${GO_TARBALL}"

    echo "正在下载 $GO_VERSION ..."
    curl -fSL "$GO_URL" -o go.tar.gz
    tar -xzf go.tar.gz
    rm go.tar.gz
else
    echo "✅ 发现已缓存的 go 目录"
fi

GO_BIN_PATH="$TOOLS_DIR/go/bin"
add_to_env "GOROOT" "$TOOLS_DIR/go"
add_to_path "$GO_BIN_PATH"
echo "✅ Go 编译器配置完毕"

# ==============================
# 7. 完成提示
# ==============================
echo "========================================="
echo "🎉 所有依赖环境配置完毕！"
echo "========================================="

if ! is_ci; then
    echo ""
    echo "💡 提示：您正在【本地环境】运行。"
    echo "由于本地 Shell 重启后环境变量会丢失，请执行以下命令使配置在当前终端生效："
    echo ""
    echo "   👉 source $ENV_FILE"
    echo ""
fi
