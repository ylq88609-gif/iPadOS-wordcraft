---
name: ipad-package-ipa
description: >-
  用于在 Mac 上为 WordCraft for iPad 编译 ARM64 静态库、运行 XcodeGen、生成无签名 WordCraft.ipa 并执行完整产物自检。
  当用户要求打包、出包、生成 .ipa 或排查打包/空包/闪退问题时触发。
---

# WordCraft for iPad 一键打包与自动验收

本技能使用项目根目录的加固版 `build_on_mac.sh` 完成全流程打包，并自动拦截历史高频故障（`DYLD` 闪退、丢失中文翻译、144B 空 `.ipa`）。

## 执行步骤

### 1. 打包前快速检查
- 确认当前处于项目根目录 `/Users/lulusama/Desktop/wordcraft`（或仓库根目录）。
- 检查 `build_on_mac.sh` 存在且具备可执行权限（若无权限先运行 `chmod +x build_on_mac.sh`）。
- 确认用户没有意外向 `apps/wordcraft-ios/xcode-host/WordFonts/` 放入未授权商业字体。

### 2. 执行打包脚本
- **常规完整打包**（修改了任意 Rust 代码时必须使用）：
  ```bash
  ./build_on_mac.sh
  ```
- **极速重打包**（仅修改了 `apps/wordcraft-ios/xcode-host/` 下的 `main.m`、`Info.plist`、`project.yml` 且静态库未变）：
  ```bash
  ./build_on_mac.sh --skip-rust
  ```
- 如用户希望保留历史包备份，可附加 `--keep-copy`（同时归档到 `dist/WordCraft-<时间戳>.ipa`）。

### 3. 验收标准（全部满足才算成功）
向用户汇报时，必须核对脚本输出中的以下 4 项结果：
1. `CRAFT_I18N_DIR` 已就绪且已传入 Rust 编译。
2. `libwordcraft_ios.a` 存在且无残留 `libwordcraft_ios.dylib`。
3. `otool -L` 校验通过，主二进制未链接 `libwordcraft_ios.dylib`。
4. `~/Desktop/WordCraft.ipa` 体积正常（几十 MB，绝非 144B 空包）。

### 4. 常见失败自愈排查
- **报错提示找不到 iOS SDK / 平台**：提示或在获得许可后执行 `xcodebuild -downloadPlatform iOS`。
- **`xcodegen: command not found`**：通过 `brew install xcodegen` 安装。
- **克隆 `/tmp/craft-i18n` 网络超时**：检查网络代理，或确认本地是否已有缓存目录并通过 `CRAFT_I18N_DIR=...` 指定。

### 5. 收尾指引
打包验收通过后，告知用户产物路径 `~/Desktop/WordCraft.ipa` 与实际大小，提醒可直接通过 AirDrop 发送到 iPad 使用自签工具安装验证。
