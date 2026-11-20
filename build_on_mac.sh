bash << 'SCRIPT'
set -e

if [ -f "$PWD/apps/wordcraft-ios/Cargo.toml" ]; then
    PROJECT_DIR="$PWD"
else
    CARGO_FILE=$(find "$HOME" -maxdepth 6 \
        -not -path "*/target/*" \
        -not -path "*/.cargo/*" \
        -not -path "*/.Trash/*" \
        -not -path "*/Library/Caches/*" \
        -path "*/apps/wordcraft-ios/Cargo.toml" 2>/dev/null | head -n 1)
    if [ -n "$CARGO_FILE" ]; then
        PROJECT_DIR="$(dirname "$(dirname "$(dirname "$CARGO_FILE")")")"
    fi
fi

if [ -z "$PROJECT_DIR" ]; then
    echo "❌ 未找到 wordcraft 目录，请先 cd 进入你的 wordcraft 文件夹后再运行。"
    exit 1
fi

echo "=== 1. 定位项目并编译 Rust 静态库 ==="
cd "$PROJECT_DIR"
rustup target add aarch64-apple-ios
cargo build --release -p wordcraft-ios --target aarch64-apple-ios

echo "=== 2. 准备 Xcode 工程与字体资源 ==="
cd "$PROJECT_DIR/apps/wordcraft-ios/xcode-host"
mkdir -p WordFonts
for legacy in msyh.ttc msyhbd.ttc simsun.ttc Deng.ttf Dengb.ttf simkai.ttf simfang.ttf simhei.ttf YuGothB.ttc YuGothM.ttc msmincho.ttc meiryob.ttc meiryo.ttc msgothic.ttc calibri.ttf calibrib.ttf times.ttf timesbd.ttf arial.ttf; do
    rm -f "WordFonts/$legacy"
done

if [ ! -f Info.plist ]; then
cat << 'EOF' > Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UILaunchScreen</key>
    <dict/>
</dict>
</plist>
EOF
fi

cat << 'EOF' > project.yml
name: WordCraft
options:
  bundleIdPrefix: com.artcraft
  deploymentTarget:
    iOS: "16.0"
targets:
  WordCraft:
    type: application
    platform: iOS
    sources:
      - main.m
      - path: WordFonts
        type: folder
    info:
      path: Info.plist
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.artcraft.wordcraft.ipad
        TARGETED_DEVICE_FAMILY: "2"
        SUPPORTED_PLATFORMS: iphoneos
        ARCHS: arm64
        ONLY_ACTIVE_ARCH: NO
        ENABLE_BITCODE: NO
        OTHER_LDFLAGS:
          - $(inherited)
          - -ObjC
          - -lc++
          - -lresolv
    dependencies:
      - sdk: UIKit.framework
      - sdk: UniformTypeIdentifiers.framework
      - sdk: Metal.framework
      - sdk: MetalKit.framework
      - sdk: QuartzCore.framework
      - sdk: CoreGraphics.framework
      - sdk: CoreText.framework
      - sdk: Foundation.framework
      - sdk: Security.framework
      - sdk: SystemConfiguration.framework
      - framework: ../../../target/aarch64-apple-ios/release/libwordcraft_ios.a
        embed: false
EOF

if ! command -v xcodegen &> /dev/null; then
    brew install xcodegen
fi

rm -rf WordCraft.xcodeproj build Payload
xcodegen generate

echo "=== 3. 编译真机 Release 包并封装 .ipa ==="
xcodebuild -project WordCraft.xcodeproj \
           -scheme WordCraft \
           -configuration Release \
           -sdk iphoneos \
           -destination "generic/platform=iOS" \
           -arch arm64 \
           -derivedDataPath build \
           CODE_SIGN_IDENTITY="" \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGNING_ALLOWED=NO \
           build

APP_PATH="build/Build/Products/Release-iphoneos/WordCraft.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ 编译未生成 WordCraft.app，请把上方报错发给我。"
    exit 1
fi

mkdir -p Payload
cp -r "$APP_PATH" Payload/
rm -f ~/Desktop/WordCraft.ipa
zip -r -q ~/Desktop/WordCraft.ipa Payload
rm -rf Payload

echo "🎉 打包完成："
ls -lh ~/Desktop/WordCraft.ipa
SCRIPT
