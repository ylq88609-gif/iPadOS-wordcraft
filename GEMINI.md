# WordCraft for iPad — Antigravity / Gemini 专属工程规范

> 本文件作为上游 `AGENTS.md` 的补充规则，专门约束 **WordCraft for iPad (Rust + egui + XcodeGen)** 的快速迭代、验证、无签名 `.ipa` 打包及持续进化流程。

---

## 1. 环境与关键信息

- **Mac 本地工作目录**：`/Users/lulusama/Desktop/wordcraft`
- **目标平台**：iPadOS (`aarch64-apple-ios`, ARM64)，通过 Mac 编译生成无签名 `~/Desktop/WordCraft.ipa`，由用户 AirDrop 至 iPad 自签安装。
- **多语言依赖**：`CRAFT_I18N_DIR=/tmp/craft-i18n`（仓库 `storytold/craft-i18n`，锁定 commit 见根目录 `craft-i18n.rev`），iOS 默认界面语言 `WORDCRAFT_LANGUAGE=zh-CN`。
- **云端进度表（Google Sheets）**：
  - 名称：《WordCraft for iPad 迁移至 Antigravity 进度转移表》
  - Spreadsheet ID：`1KVEn44NodrIZsAXeTG81TcwEowWfACa2rsNLcyWH1D0`
- **源码唯一真相源**：Mac 本地 Git 仓库 + GitHub。**严禁**把源码或 Rust `target/` 目录放入 Google Drive 同步。

---

## 2. iPad 移植关键文件地图

| 路径 | 职责说明 |
| :--- | :--- |
| `apps/wordcraft-ios/Cargo.toml` | 固定 `crate-type = ["staticlib", "rlib"]` 与 `wordcraft-fonts` 依赖 |
| `apps/wordcraft-ios/src/lib.rs` | iOS 启动加载用户字体、文件打开/导出桥接、IME/快捷键/剪贴板/滚动注入、当前 `Y_OFFSET=18.0` 光标校准与 4pt 防抖 |
| `apps/wordcraft-ios/xcode-host/main.m` | `WordCraftImeView (UITextInput)`、`gInBecome` 防递归锁、`UIKeyCommand`、`CADisplayLink` 60/120Hz 惯性滚动、`UIDocumentPickerViewController`、`UIPasteboard`、`zh-CN` 注入 |
| `apps/wordcraft-ios/xcode-host/project.yml` | XcodeGen 配置：锁定 `SUPPORTED_PLATFORMS: iphoneos` 与 `ARCHS: arm64` |
| `apps/wordcraft-ios/xcode-host/Info.plist` | iPad 全屏启动 (`UILaunchScreen`)、`UIDeviceFamily=[2]`、四方向旋转、文件共享权限 |
| `apps/wordcraft-ios/xcode-host/WordFonts/` | 合规开源字体（SIL OFL 1.1：NotoSans/Serif CJK、Carlito 等）及 `THIRD_PARTY_FONT_LICENSES.txt` |
| `crates/ui-egui/src/app/frame.rs` | iOS 顶部 `24pt` / 底部 `16pt` 安全区面板 |
| `crates/ui-egui/src/frame.rs` & `table_resize.rs` | iOS 图形手柄热区放大（`GRAB_R=18pt`, `HANDLE_R=6.5pt`）与表格边框缩放热区放大（`REACH_PX=14pt`） |
| `crates/ui-egui/src/options.rs` | 独立 3 页式字体管理界面（字体列表 / 预览 / 管理） |
| `build_on_mac.sh` | 加固版一键编译、自检与无签名 `.ipa` 打包脚本 |

---

## 3. 绝对红线（历史踩坑记录，禁止重犯）

1. **禁止动态库混连导致闪退 (`DYLD Library missing`)**
   - `apps/wordcraft-ios/Cargo.toml` 必须保持 `staticlib + rlib`。
   - 打包前必须清理残留的 `target/aarch64-apple-ios/release/libwordcraft_ios.dylib`。
   - 打包后必须用 `otool -L` 确认 `WordCraft.app` 主二进制未链接 `libwordcraft_ios.dylib`。
2. **杜绝 144B 空 `.ipa` 包**
   - `xcodebuild` 必须显式传入 `-sdk iphoneos -destination "generic/platform=iOS"` 与 `LIBRARY_SEARCH_PATHS`。
   - 封装前必须删除旧的 `~/Desktop/WordCraft.ipa`，封装后必须校验产物大小（正常应为几十 MB，小于 5MB 视为失败）。
3. **字体版权红线**
   - 严禁放回已清理的 19 个未授权商业字体（`msyh*`, `simsun*`, `Deng*`, `simkai*`, `simfang*`, `simhei*`, `YuGoth*`, `msmincho*`, `meiryo*`, `msgothic*`, `calibri*`, `times*`, `arial*`）。
   - 新增字体必须开源合规，并同步更新 `WordFonts/THIRD_PARTY_FONT_LICENSES.txt`。
4. **IME 与交互稳定性红线**
   - 修改 `main.m` 中 `WordCraftImeView` 时必须保留 `gInBecome` 防递归锁。
   - 双指触屏滑动（`panTouch`）与触控板滚动（`panTrackpad`）已拆分以释放单指拖拽给图形/选区，修改手势时不得破坏该隔离。
5. **XcodeGen `Info.plist` 全屏防覆盖红线**
   - `apps/wordcraft-ios/xcode-host/project.yml` 的 `info.properties` 必须完整保留 `UILaunchScreen: {}`、`UIDeviceFamily: [2]`、`UIRequiresFullScreen: true`、`UISupportedInterfaceOrientations~ipad`（4 方向）、`UIFileSharingEnabled: true` 与 `LSSupportsOpeningDocumentsInPlace: true`，因为每次 `xcodegen generate` 都会覆盖重写 `Info.plist`（缺少 `UILaunchScreen` 会导致 iPad 退化为非全屏兼容缩放）。
   - `build_on_mac.sh` 验收阶段会自动用 `plutil -p` 校验这些字段。
6. **高风险操作人工确认**
   - 执行 `git push --force`、删除备份目录（如 `_Backup_Before_Font_Alpha`）或删除 Google Sheet 数据前，必须先征求用户明确确认。

---

## 4. 高频研发与验证命令

```bash
# 1. Rust iOS 目标语法与类型秒查（1~3秒）
cargo check -p wordcraft-ios --target aarch64-apple-ios

# 2. Mac 桌面端秒开验证 UI / 字体 / 中文界面 / DOCX 逻辑（无需打 .ipa）
CRAFT_I18N_DIR=/tmp/craft-i18n WORDCRAFT_LANGUAGE=zh-CN cargo run -p wordcraft

# 3. 完整编译 + 自检 + 生成 ~/Desktop/WordCraft.ipa
./build_on_mac.sh

# 4. 仅改动了 xcode-host (main.m / Info.plist / project.yml) 时快速重打包
./build_on_mac.sh --skip-rust
```

---

## 5. 当前待办清单（整体完成率 81.8%）

- **[P0 / 任务 10 - 部分完成]** 从 `winit` / `egui-winit` iOS 底层排查 `safeAreaInsets` 坐标差异，替代当前硬编码 `Y_OFFSET=18.0`。
- **[P1 / 任务 11 - 未开始]** 顶部 Ribbon 窄屏/竖屏自适应（横向滚动或折叠）；配置 `WORDCRAFT_DICTIONARIES` 指向 iOS 沙盒词典目录并评估中文校对方案。
- **[P2 / 体验优化]**
  - 锁定 iOS 中文环境下新建空白文档默认字体为 `Carlito + Noto Sans CJK SC`（避免误选 `Al Nile + Apple SD Gothic Neo`）。
  - 适配 iPad 分屏（Split View）与台前调度（Stage Manager）动态安全区。
  - 选中图片/形状时增加悬浮快捷胶囊条（浮于文字上方 / 添加超链接）。
  - 优化外接键盘与软键盘切换时光标矩形跟随精度及滚动惯性阻尼系数。

---

## 6. Agent 持续更新规则（自我进化闭环）

每当完成一次功能迭代、修复一次 iPad 真机 Bug 或调整构建流程后：
1. **沉淀新坑**：将新发现的根因和规避方法追加到本文件第 3 节「绝对红线」。
2. **刷新进度**：更新本文件第 5 节「当前待办清单」，并按需使用 `sync-progress-sheet` 技能同步云端 Google Sheet 进度表。
3. **版本入库**：整理简洁的中文 commit 说明，引导或协助用户提交推送到 GitHub。
