#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

echo "=== 1. 检查 Mac 端 Rust 环境 ==="
if ! command -v rustup &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

echo "=== 2. 校验内置开源字体目录 (SIL OFL 1.1) ==="
WORDFONTS_DIR="apps/wordcraft-ios/xcode-host/WordFonts"
mkdir -p "$WORDFONTS_DIR"
# 若本地存在任何遗留的未授权商业字体，自动清理以确保合规
for legacy in msyh.ttc msyhbd.ttc simsun.ttc Deng.ttf Dengb.ttf simkai.ttf simfang.ttf simhei.ttf YuGothB.ttc YuGothM.ttc msmincho.ttc meiryob.ttc meiryo.ttc msgothic.ttc calibri.ttf calibrib.ttf times.ttf timesbd.ttf arial.ttf; do
    if [ -f "$WORDFONTS_DIR/$legacy" ]; then
        echo "🧹 清理未授权商业字体: $legacy"
        rm -f "$WORDFONTS_DIR/$legacy"
    fi
done

echo "=== 3. 编译 iPad Pro 2018 (ARM64) 原生静态库 ==="
rustup target add aarch64-apple-ios
cargo build --release -p wordcraft-ios --target aarch64-apple-ios

echo "=== 4. 检查并生成 Xcode 工程结构 ==="
if ! command -v xcodegen &> /dev/null; then
    if command -v brew &> /dev/null; then
        brew install xcodegen
    else
        echo "❌ 未检测到 xcodegen，请先安装 Homebrew 或运行 brew install xcodegen"
        exit 1
    fi
fi

cd apps/wordcraft-ios/xcode-host
xcodegen generate

echo "=== 5. 免证书编译真机 Release 包并封装为 .ipa ==="
rm -rf build Payload
xcodebuild -project WordCraft.xcodeproj \
           -scheme WordCraft \
           -configuration Release \
           -sdk iphoneos \
           -derivedDataPath build \
           CODE_SIGN_IDENTITY="" \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGNING_ALLOWED=NO

mkdir -p Payload
cp -r build/Build/Products/Release-iphoneos/WordCraft.app Payload/
zip -r -q ~/Desktop/WordCraft.ipa Payload
rm -rf Payload

echo "=========================================================="
echo "🎉 打包大功告成！"
echo "独立安装包已生成在 Mac 桌面: ~/Desktop/WordCraft.ipa"
echo "请直接通过 AirDrop (隔空投送) 发送到你的 iPad 用第三方签名工具自签安装！"
echo "=========================================================="
