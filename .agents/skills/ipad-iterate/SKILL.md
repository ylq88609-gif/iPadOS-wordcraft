---
name: ipad-iterate
description: >-
  用于 WordCraft for iPad 项目的快速代码迭代、Rust iOS 交叉检查、Mac 桌面端快速验证以及 iPad 崩溃日志 (.ips) 排错。
  当用户要求开发新功能、修复 Bug、优化交互/字体/安全区，或提供 .ips 崩溃日志时触发。
---

# WordCraft for iPad 快速迭代与验证流程

使用「由快到慢」的反馈闭环，先在几秒内完成编译与逻辑验证，确认无误后再打包 `.ipa`，大幅节省迭代时间。

## 执行步骤

### 1. 读取上下文与红线
- 修改代码前先确认根目录 `GEMINI.md` 中的**关键文件地图**与**绝对红线**（特别是字体合规、静态库配置、`gInBecome` 递归锁、双指手势拆分）。
- 如需了解某项任务历史背景，可结合 `sync-progress-sheet` 技能读取云端进度表。

### 2. 处理 iPad 崩溃日志（如用户提供了 `.ips` 文件）
- 读取 `.ips` 文件中的 `exception`、`termination` 及崩溃线程的 `frames` 堆栈。
- 重点区分三类高频问题：
  - `DYLD` / `Library not loaded`：检查 `libwordcraft_ios.dylib` 残留与 `Cargo.toml` 的 `staticlib`。
  - Obj-C 递归/主线程异常：检查 `apps/wordcraft-ios/xcode-host/main.m` 的 `WordCraftImeView`、`gInBecome` 与 `CADisplayLink`。
  - Rust panic / 布局坐标异常：定位 `apps/wordcraft-ios/src/lib.rs` 或 `crates/ui-egui/` 对应源码。

### 3. 修改代码并执行三级快速验证
1. **L1 — iOS 目标秒查（必跑，1~3 秒）**
   ```bash
   cargo check -p wordcraft-ios --target aarch64-apple-ios
   ```
   若出现编译或借用检查错误，直接根据报错自行修复并重跑，直到零错误。
2. **L2 — 单元测试（改动核心 crate 时必跑）**
   ```bash
   cargo test -p <被修改的crate名>
   ```
3. **L3 — Mac 桌面端秒开验证（改动 UI / 字体 / 多语言 / DOCX 逻辑时推荐）**
   确保 `/tmp/craft-i18n` 已存在后提示或运行：
   ```bash
   CRAFT_I18N_DIR=/tmp/craft-i18n WORDCRAFT_LANGUAGE=zh-CN cargo run -p wordcraft
   ```

### 4. 衔接出包与经验沉淀
- 当验证通过且需要真机测试时，衔接 `ipad-package-ipa` 技能产出 `~/Desktop/WordCraft.ipa`。
- 若本次解决了新的技术坑，提醒用户将其沉淀到 `GEMINI.md` 并同步进度表。
