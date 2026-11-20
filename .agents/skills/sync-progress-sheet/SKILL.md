---
name: sync-progress-sheet
description: >-
  用于读取或更新《WordCraft for iPad 迁移至 Antigravity 进度转移表》(Google Sheets) 并同步本地 GEMINI.md。
  当用户询问当前项目进度、完成新任务需要登记进度、或希望将踩坑经验沉淀为长期记忆时触发。
---

# 同步 WordCraft iPad 进度表与本地经验

保持「云端 Google Sheet 进度表」与「本地 `GEMINI.md`」双向一致，让 Agent 在跨会话、跨模型迭代时始终掌握最新状态。

## 目标表格信息

- **Spreadsheet ID**：`1KVEn44NodrIZsAXeTG81TcwEowWfACa2rsNLcyWH1D0`
- **主要工作表**：
  - `进度与问题追踪`（任务 1~11、状态、根因方案、涉及文件、待办建议与汇总行）
  - `关键文件与环境清单`
  - `标准构建与调试命令`

## 执行步骤

### 1. 读取最新进度（只读）
在修改任何单元格前，务必先读取当前内容以确认准确行号，绝不凭记忆猜测行号：
```bash
gsheets readonly read-all 1KVEn44NodrIZsAXeTG81TcwEowWfACa2rsNLcyWH1D0
```

### 2. 更新云端进度表（精准最小范围写入）
- 仅更新状态发生变化的对应单元格（如 D 列「当前状态」、E 列「核心根因与已验证方案」、G 列「后续待办」），**严禁整表覆盖**，避免破坏格式与汇总统计公式。
- 示例（先核对实际行号后再写）：
  ```bash
  gsheets mutate write 1KVEn44NodrIZsAXeTG81TcwEowWfACa2rsNLcyWH1D0 "'进度与问题追踪'!D11:E11" "已完成|排查并修复 safeAreaInsets 坐标差异，移除硬编码 Y_OFFSET"
  ```
- **安全红线**：绝不执行 `delete-sheet`、`delete-rows`、`clear` 等破坏性命令，除非用户明确指定。
- 如果 `gsheets` 尚未登录，请提示用户在 Mac 端 Antigravity 的 Plugins Manager 中完成 Google Sheets 插件登录。

### 3. 同步沉淀到本地 `GEMINI.md`
- 更新 `GEMINI.md` 第 5 节「当前待办清单」。
- 如本次迭代踩到了新的 Mac/iPad/Rust 坑，追加一条简洁记录到 `GEMINI.md` 第 3 节「绝对红线」。
- 提醒用户将 `GEMINI.md` 变更随代码一起 `git commit && git push` 到 GitHub。
