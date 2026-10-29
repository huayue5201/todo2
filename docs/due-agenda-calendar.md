# 时间维度：现状与下一步（due → 议程 → 月历）

> 本文只记录**没做**的部分，避免下次接手重新推演。
> 已完成的部分见 README 的 `:TodoDue` / `due:` 筛选 / 抽屉徽标 章节。

---

## 0. 已完成（P1，无需再做）

| 能力 | 入口 | 位置 |
| --- | --- | --- |
| 到期日字段（纯日期 `@YYYY-MM-DD`） | `:TodoDue [date]` | `lua/todo2/handlers/due.lua` |
| 解析 / 格式化 / 高亮 / 归一化 | — | `lua/todo2/utils/due.lua` |
| 筛选 `due:today\|week\|overdue\|none\|<date>` | `:TodoFilter`、抽屉 `f` | `lua/todo2/render/filter.lua` |
| 抽屉行内徽标 | `:TodoDrawer` | `lua/todo2/ui/drawer.lua:337-341` |
| 抽屉内 `u` 改到期日 | 抽屉 | `lua/todo2/ui/drawer.lua:789` |
| 代码侧 virt_lines due 段 | 自动 | `lua/todo2/render/todo_render.lua:73-77` |
| MCP 字段 `due` | create/update | `mcp/todo2-mcp.lua` |

设计约束（不要推翻）：
- **只存日期**，不存时间。时间戳会引入时区与边界语义，表现力由正文承担。
- `@` 前缀 + ISO 日期，可被任意工具 grep；非法日期写入时拒绝，不静默丢弃。

---

## 1. 下一步 A：议程视图 `:TodoAgenda`（不引入依赖）

目标：一条命令看「过期 / 今天 / 未来」的任务，可跳转。**这不是月历**，是时间轴列表。

### 需求

- `:TodoAgenda [range]`，range ∈ `today | week | month | all`，默认 `week`
- 输出到 quickfix（可 `<CR>` 跳转、可 `:cnext` 批量过），按日期升序
- 分组标题行：`⚠ 已过期 (n)` / `今天 YYYY-MM-DD (n)` / `本周 (n)` / `之后 (n)` / `无日期 (n)`
- `all` 时「无日期」放最后，且默认折叠或直接省略（加 `!` 才包含）
- 排序：日期升序 → 同日期按 status（doing → todo → completed）→ 文件路径 → 行号
- 完成/归档任务默认排除（与抽屉一致），`!` 时包含

### 实现要点（复用现有件，不要另起解析）

```
lua/todo2/handlers/agenda.lua        -- 命令层：解析 range、组装 qfitems
  ├ require("todo2.ui.file_manager").get_todo_files(project)   -- TODO 文件发现
  ├ require("todo2.render.scheduler").get_parse_tree(path)     -- 已有解析树，不要再读文件
  ├ require("todo2.utils.due").urgency(due, status)          -- 差天数/档位统一入口，不要在命令层再算日期
  └ require("todo2.render.filter").parse({ "due:" .. range })  -- 复用筛选语义
```

回退方案：若不想碰 quickfix，可复用 `lua/todo2/ui/window.lua`（已有浮动窗口封装）开一个只读浮窗，
但 quickfix 更省代码且天然可跳转 —— 优先 quickfix。

### 未决问题（实现前先决定）

1. 分组标题行在 quickfix 里是「`text` 为标题、`filename` 为空」的无效条目，
   `:cnext` 会跳过但视觉上有噪音。是否改用 loclist + 自绘缓冲？
2. 项目跨文件去重：同一 id 在多个 TODO 文件出现（继承锚点）只留一份，规则同 `preview`。
3. `month` 范围的定义：自然月（1 号到月末）还是未来 30 天？建议自然月，与日历一致。

### 映射（加在用户侧 config，本插件不提供默认映射）

```lua
vim.keymap.set("n", "<leader>mta", "<cmd>TodoAgenda<cr>", { desc = "议程：本周到期任务" })
vim.keymap.set("n", "<leader>mtA", "<cmd>TodoAgenda all!<cr>", { desc = "议程：全部（含无日期/已完成）" })
```

---

## 2. 下一步 B：calendar.nvim 月历集成（P2）

> **状态（2026-10-29）**：已落地「只打点」版 —— 本地 fork
> `~/neovim-plugins/calendar.nvim`（commit `ca1a393`，分支 `fix/marks-reset` 待提 PR），
> 配置在 dotfiles `lua/plugins/calendar.lua`，映射 `<leader>mvc`。
> 上游 PR 合并后可把 `dir = "~/neovim-plugins/calendar.nvim"` 换成 `src = "https://github.com/wsdjeg/calendar.nvim"`。
> 下面的「未做」部分保留：钻取到议程、多点/多色标记仍需上游 API 扩展。
>
> **状态（2026-10-29 增补）**：PR 已提 —— <https://github.com/wsdjeg/calendar.nvim/pull/14>（`fix/marks-reset`）。
> 已决定**不等上游**：fork 即加载源，`view`/`extensions` 按自己的时间视图重构，
> 设计基线见 fork 的 `docs/refactor-time-view.md`（v2 数据契约 / 单元格加宽 / 当天任务浮窗 / todo2 集成分期 P0-P2）。
> 该文档同时修正了上文未发现的两个问题：标记 `virt_text_pos='overlay'` 遮住日期数字、单元格几何 4 列硬编码。

上游仓库：<https://github.com/wsdjeg/calendar.nvim>（fork 在 `huayue5201/calendar.nvim`）

### 硬阻塞：`marked_days` 只增不减（fork 已修）

`lua/calendar/extensions.lua`：

- `:7` `local marked_days = {}`（模块级）
- `:40-49` `M.mark()` 只往里写，`M.on_change()` **从不重置**

后果：标记在整个 nvim 生命周期内残留 —— 任务删了 / 改期了 / 换项目了，旧点还在。
渲染层没问题（`view.lua:133-138` 每次重绘先 `del_extmark` 再画），是数据陈旧。

上游修法（2 行）：

```lua
function M.on_change(year, month)
  marked_days = {}   -- 每次重绘从当前数据重算
  ...
```

**绕过方案已验证不可行**：重置 `package.loaded["calendar.extensions"]` 再重新注册
无效，因为 `lua/calendar/view.lua:15` 在模块加载时 `local ext = require(...)` 缓存了引用，
view 仍指向旧表。

路线：先提 PR（中英双语描述 + 该 2 行 patch），一周无响应再决定
「本地 patch + pin commit」而非维护完整 fork。

### 表现力上限（即使 bug 修好）

`has_marks` 只有布尔值：一天一个图标、无数量、无优先级、无标题，点开才知道是什么。
所以月历只能做「哪天有活」的气场提示，信息主体仍在议程视图（下一步 A）。

### 集成步骤（依赖 PR 合并后）

1. `calendar.setup { extensions = { { on_change = mark_due_days } } }`
2. `mark_due_days(year, month)`：取当月范围的 due 任务
   （`due.parse_spec("month")` + `due.hit(due, spec, status)` 已能表达「本月」，无需新增 API）
   对每个日期调 `ext.mark(year, month, day, { icon = "•", hl = "Todo2DueSoon" })`
3. `ext.on_change` 后同步刷新；任务变更（`todo2` 的 store 事件）时触发 `calendar.view.redraw()`
4. 点击某天 → 打开 `:TodoAgenda day`（P2 结束后应有 `day` 范围）= 日历 → 议程的钻取链

### 不引入依赖的替代

自己画月历约 200 行（float + extmark + 日期算术），但会跟 calendar.nvim 的
跳转/编辑/自然语言输入功能重复。只有在 A 落地并且真的每天要看月历时才做。

---

## 3. 更后面（暂不设计）

- due 带时间 `@YYYY-MM-DDTHH:MM`：等出现「按小时排程」的真实需求再说，涉及排序与时区
- 重复任务（`@every week`）：与文件内文本真相模型冲突，优先级最低
- 日历侧写回（在月历里拖动改期）：跨真实来源的写路径，风险高，需单独设计
