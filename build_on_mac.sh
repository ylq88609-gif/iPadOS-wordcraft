#!/usr/bin/env bash
set -euo pipefail

# WordCraft for iPad — 加固版 Mac 一键编译与无签名 .ipa 打包脚本
# 用法:
#   ./build_on_mac.sh               # 全量编译 Rust 静态库 + XcodeGen + 打 .ipa + 自动验收
#   ./build_on_mac.sh --skip-rust   # 跳过 Rust 编译（仅修改 main.m / Info.plist / project.yml 时提速）
#   ./build_on_mac.sh --keep-copy   # 除桌面最新包外，同时在 dist/ 保留带时间戳的历史版本

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SKIP_RUST=0
KEEP_COPY=0
for arg in "$@"; do
  case "$arg" in
    --skip-rust) SKIP_RUST=1 ;;
    --keep-copy) KEEP_COPY=1 ;;
    -h|--help)
      echo "用法: ./build_on_mac.sh [--skip-rust] [--keep-copy]"
      exit 0
      ;;
    *)
      echo "❌ 未知参数: $arg"
      echo "用法: ./build_on_mac.sh [--skip-rust] [--keep-copy]"
      exit 1
      ;;
  esac
done

IOS_RELEASE_DIR="$SCRIPT_DIR/target/aarch64-apple-ios/release"
XCODE_HOST_DIR="$SCRIPT_DIR/apps/wordcraft-ios/xcode-host"
WORDFONTS_DIR="$XCODE_HOST_DIR/WordFonts"
CRAFT_I18N_DIR="${CRAFT_I18N_DIR:-/tmp/craft-i18n}"
OUTPUT_IPA="$HOME/Desktop/WordCraft.ipa"

echo "=== 1. 检查 Mac 端 Rust 与基础构建环境 ==="
if ! command -v rustup >/dev/null 2>&1; then
  echo "⏳ 未检测到 rustup，正在安装 Rust 工具链..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "❌ 未检测到 xcodebuild，请先安装 Xcode 并执行: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

echo "=== 2. 检查并准备多语言资源 (craft-i18n) ==="
if [ ! -d "$CRAFT_I18N_DIR" ]; then
  echo "⏳ 正在克隆 storytold/craft-i18n 到 $CRAFT_I18N_DIR ..."
  git clone https://github.com/storytold/craft-i18n.git "$CRAFT_I18N_DIR"
fi

if [ -f "$SCRIPT_DIR/craft-i18n.rev" ] && [ -d "$CRAFT_I18N_DIR/.git" ]; then
  TARGET_REV="$(tr -d '[:space:]' < "$SCRIPT_DIR/craft-i18n.rev")"
  if [ -n "$TARGET_REV" ]; then
    CURRENT_REV="$(git -C "$CRAFT_I18N_DIR" rev-parse HEAD 2>/dev/null || true)"
    if [ "$CURRENT_REV" != "$TARGET_REV" ]; then
      echo "🔄 切换 craft-i18n 至锁定版本: $TARGET_REV"
      git -C "$CRAFT_I18N_DIR" fetch --all --quiet || true
      git -C "$CRAFT_I18N_DIR" checkout --quiet "$TARGET_REV" || echo "⚠️ 无法切换到 $TARGET_REV，继续使用当前本地版本 $CURRENT_REV"
    fi
  fi
fi
export CRAFT_I18N_DIR
echo "✅ CRAFT_I18N_DIR=$CRAFT_I18N_DIR"

echo "=== 3. 校验内置开源字体目录 (SIL OFL 1.1 合规检查) ==="
mkdir -p "$WORDFONTS_DIR"
for legacy in \
  msyh.ttc msyhbd.ttc simsun.ttc Deng.ttf Dengb.ttf simkai.ttf simfang.ttf simhei.ttf \
  YuGothB.ttc YuGothM.ttc msmincho.ttc meiryob.ttc meiryo.ttc msgothic.ttc \
  calibri.ttf calibrib.ttf times.ttf timesbd.ttf arial.ttf; do
  if [ -f "$WORDFONTS_DIR/$legacy" ]; then
    echo "🧹 清理遗留未授权商业字体: $legacy"
    rm -f "$WORDFONTS_DIR/$legacy"
  fi
done

if [ ! -f "$WORDFONTS_DIR/THIRD_PARTY_FONT_LICENSES.txt" ]; then
  echo "⚠️ 警告: 未找到 $WORDFONTS_DIR/THIRD_PARTY_FONT_LICENSES.txt，请确认开源字体目录完整。"
fi

echo "=== 4. 清理残留动态库并编译 iOS ARM64 静态库 ==="
# 防止动态库残留导致启动时 DYLD Library missing 闪退
rm -f "$IOS_RELEASE_DIR/libwordcraft_ios.dylib"

if [ "$SKIP_RUST" -eq 0 ]; then
  rustup target add aarch64-apple-ios >/dev/null
  echo "🔨 开始编译 wordcraft-ios (aarch64-apple-ios --release)..."
  CRAFT_I18N_DIR="$CRAFT_I18N_DIR" cargo build --release -p wordcraft-ios --target aarch64-apple-ios
  # 再次清理可能生成的 dylib，强制后续只链接静态库
  rm -f "$IOS_RELEASE_DIR/libwordcraft_ios.dylib"
else
  echo "⏭️ 已启用 --skip-rust，跳过 Rust 静态库编译"
fi

if [ ! -f "$IOS_RELEASE_DIR/libwordcraft_ios.a" ]; then
  echo "❌ 未找到静态库: $IOS_RELEASE_DIR/libwordcraft_ios.a"
  echo "   请去掉 --skip-rust 重新完整编译，并确认 apps/wordcraft-ios/Cargo.toml 包含 staticlib。"
  exit 1
fi
echo "✅ 静态库就绪: $(ls -lh "$IOS_RELEASE_DIR/libwordcraft_ios.a" | awk '{print $5, $9}')"

echo "=== 5. 检查 XcodeGen 并生成 Xcode 工程 ==="
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "⏳ 正在通过 Homebrew 安装 xcodegen..."
    brew install xcodegen
  else
    echo "❌ 未检测到 xcodegen，请先安装 Homebrew 或手动运行: brew install xcodegen"
    exit 1
  fi
fi

cd "$XCODE_HOST_DIR"
xcodegen generate

echo "=== 6. 免证书编译真机 Release 包 ==="
rm -rf build Payload "$OUTPUT_IPA"
xcodebuild \
  -project WordCraft.xcodeproj \
  -scheme WordCraft \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  LIBRARY_SEARCH_PATHS="$IOS_RELEASE_DIR" \
  build

APP_PATH="$XCODE_HOST_DIR/build/Build/Products/Release-iphoneos/WordCraft.app"
APP_BIN="$APP_PATH/WordCraft"

echo "=== 7. 自动产物验收 (防 DYLD 闪退 & 防 144B 空包) ==="
if [ ! -d "$APP_PATH" ] || [ ! -f "$APP_BIN" ]; then
  echo "❌ 构建未产出有效的 WordCraft.app: $APP_PATH"
  echo "   提示: 如首次在当前 Xcode 构建 iOS，请先运行: xcodebuild -downloadPlatform iOS"
  exit 1
fi

echo "🔍 检查动态库依赖 (otool -L)..."
OTOOL_OUT="$(otool -L "$APP_BIN")"
echo "$OTOOL_OUT" | head -n 20
if echo "$OTOOL_OUT" | grep -q "libwordcraft_ios\.dylib"; then
  echo "❌ 验收失败: WordCraft 二进制意外链接了 libwordcraft_ios.dylib！真机启动将闪退。"
  exit 1
fi
echo "✅ 动态库依赖校验通过（未链接 libwordcraft_ios.dylib）"

echo "🔍 检查 iPad 全屏与文件共享 Info.plist 配置..."
PLIST_DUMP="$(plutil -p "$APP_PATH/Info.plist")"
for required_key in UILaunchScreen UISupportedInterfaceOrientations UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace UIApplicationSupportsIndirectInputEvents CFBundleIcons; do
  if ! echo "$PLIST_DUMP" | grep -q "\"$required_key"; then
    echo "❌ 验收失败: WordCraft.app/Info.plist 缺少关键字段 $required_key（可能导致 iPad 非全屏兼容缩放或文件共享失效）！"
    echo "   请检查 apps/wordcraft-ios/xcode-host/project.yml 的 info.properties 配置。"
    exit 1
  fi
done
echo "✅ Info.plist 全屏与文件共享字段校验通过"

mkdir -p Payload
cp -R "$APP_PATH" Payload/
zip -r -q "$OUTPUT_IPA" Payload
rm -rf Payload

# 校验 .ipa 大小，杜绝 144B 空包
IPA_BYTES="$(stat -f%z "$OUTPUT_IPA")"
MIN_BYTES=$((5 * 1024 * 1024))
if [ "$IPA_BYTES" -lt "$MIN_BYTES" ]; then
  echo "❌ 验收失败: 生成的 $OUTPUT_IPA 体积过小 (${IPA_BYTES} 字节)，疑似空包！"
  exit 1
fi

IPA_HUMAN="$(ls -lh "$OUTPUT_IPA" | awk '{print $5}')"

if [ "$KEEP_COPY" -eq 1 ]; then
  mkdir -p "$SCRIPT_DIR/dist"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  ARCHIVE_IPA="$SCRIPT_DIR/dist/WordCraft-${STAMP}.ipa"
  cp "$OUTPUT_IPA" "$ARCHIVE_IPA"
  echo "📦 已归档历史版本: $ARCHIVE_IPA"
fi

echo "=========================================================="
echo "🎉 WordCraft for iPad 打包并验收成功！"
echo "📦 输出路径: $OUTPUT_IPA ($IPA_HUMAN)"
echo "📲 下一步: 直接 AirDrop 到你的 iPad，使用自签名工具安装测试。"
echo "=========================================================="
