# 📘 todo2.nvim — 代码 ↔ TODO 双向链接任务管理

面向工程师、在代码与 TODO 文件之间维护真实双向链接的任务管理器。

- **代码是任务的来源** —— 在代码行上建任务，自动记录所在函数/类/方法。
- **TODO 文件是管理界面** —— 层级、状态、标签、到期日、归档。
- **两者实时同步** —— 状态、内容、行号、代码上下文随重构自动跟随；渲染由事件驱动，无需刷新。
- **任务归属于代码** —— 任务与代码行互相跳转，关联代码行旁直接渲染标记。

**依赖：** Neovim 0.13+ 与 [nvim-store3](https://github.com/yourname/nvim-store3)。

## 它不是什么

- 不是通用 GTD / 日程工具 —— 日历和日期只服务代码任务；
- 不提供云同步 —— 没有账号、没有服务端，数据都在你的仓库里；
- 不是跨项目看板 —— 单位就是当前正在编辑的项目；
- 不替代 issue tracker —— 它跟踪的是**这个代码库里你自己**正在做的事。

## 安装

使用 lazy.nvim：

```lua
{
    "huayue5201/todo2",
    dependencies = { "nvim-store3" },
}
```

懒加载由插件端处理：命令与 TODO 文件检测先注册，`require("todo2").setup()`
在首次使用时执行。无需配置 `lazy` / `config` / `event`。

## 30 秒上手

1. 把光标放在代码行上创建任务：

   ```vim
   :TodoAdd
   ```

2. 打开 TODO 文件看到任务（含代码锚点）：

   ```vim
   :TodoFloat
   ```

3. 在代码与任务间来回跳转：

   ```vim
   :TodoJump
   ```

4. 切换状态（或在任务行按 `<CR>`）：

   ```vim
   :TodoToggle
   ```

5. 设置到期日，再看月历：

   ```vim
   :TodoDue tomorrow
   :TodoCalendar
   ```

6. 归档已完成的任务组（移入 `## Archived`）：

   ```vim
   :TodoArchive
   ```

## 高频命令

| 命令 | 功能 |
|------|------|
| `:Todo` | 打开/关闭任务抽屉；`:Todo <sub>` 等价于 `:Todo<Sub>`；`:Todo help` |
| `:TodoAdd` | 从当前代码行创建任务 |
| `:TodoDrawer` | 切换任务树抽屉 |
| `:TodoFloat` | 浮窗打开 TODO 文件 |
| `:TodoToggle` | 切换任务状态（`:TodoCycle` 循环） |
| `:TodoDel` | 智能删除；支持行范围，`!` 连子树 |
| `:TodoDue [日期\|none]` | 设置/清除到期日（`@YYYY-MM-DD`） |
| `:TodoTag [标签]` | 设置标签（`+tag` / `-tag`） |
| `:TodoFilter [条件]` | 按标签 / `status:` / `path:` / `due:` 筛选 |
| `:TodoCalendar [YYYY-MM]` | 打开项目月历 |
| `:TodoArchive` / `:TodoUnarchive` | 把任务组移入/移出 `## Archived` |
| `:TodoSync` | 手动同步当前 TODO 文件 |
| `:TodoContext [json]` | 复制任务上下文（供大模型） |
| `:TodoMcp` | 打印供 pi 等 Agent 使用的 MCP 接入信息 |

其余命令见 `:h todo2`。

## 按键

插件自带少量高频智能键（在 TODO / 代码上下文生效，否则回退原生行为）：
`<CR>` 切换状态、`<S-tab>` 循环状态、`<BS>` 智能删除（可视 `<BS>` 批量删）、
`<C-[>` 在 TODO ↔ 代码间跳转。

- 抽屉：见 `:h todo2-keymaps-drawer`（如 `C` 打开日历、可视 `<BS>` 批量删）。
- 日历：`h`/`l` 前后一天、`j`/`k` 前后一周、`H`/`L` 前后一月、`t` 今天、
  `<CR>` 当日列表、`q` 关闭 —— 完整列表见 `:h todo2-keymaps-calendar`。

## 常见问题

**文件里看到的和屏幕上不一样，id 和日期去哪了？**
`todo:<id>` 与 `@YYYY-MM-DD` 在缓冲区里被隐藏，光标压上去才显形。用
`conceal_enable = false` 可关掉隐藏，用 `conceal_due = false` 可关掉行尾到期日带。

**写在标题末尾的 `@YYYY-MM-DD` 算到期日吗？**
不算。到期日必须紧跟任务标记、在标签与正文之前：
`- [ ] todo:ab12cd @2026-07-01 #fix 修复登录`。写在末尾只是普通文本，重写该行时会给出警告，而不是静默丢弃。

**怎么批量删除任务？**
`:TodoDel` 支持行范围（`:5,9TodoDel`，或可视 `:'<,'>TodoDel`）；
`:TodoDel!` 连子树一起删；抽屉里可视 `<BS>` 删除选中的所有任务（含子树）。

**代码锚点丢了怎么办？**
先跑 `:TodoDoctor` 体检，再用 `:TodoReconcile` 从 TODO 文件重建，最后用
`:TodoLink <id>`（或 `:TodoLink` 选择）把任务重新绑定到正确的代码行。

## 文档入口

完整参考：`:h todo2`（也可 `:Todo help`）。所有功能、键位与配置的唯一真源是
`doc/todo2.txt`。

## 📄 许可证

MIT License
