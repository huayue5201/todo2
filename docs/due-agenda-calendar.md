> **历史设计记录**：日历已在 v0.2 演化为「承诺 / 活动」双层语义（`●` 承诺、`○` 活动，
> 见 `doc/todo2.txt` 的 Calendar 一节与 `:h todo2-concepts`）。本文保留当时的取舍与论证。

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
| 原生月历 + 当日列表（P2） | `:TodoCalendar` | `lua/todo2/ui/calendar/*` |

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

## 2. 下一步 B：原生月历（P2，已落地 2026-10-29）

> **状态（2026-10-29 最终）**：不走外部插件，已改为 todo2 内原生实现（约 700 行）。
> 决策记录：calendar.nvim 核心共 789 行（`view.lua` 426 / `locales.lua` 99 / `model.lua` 80 /
> `extensions.lua` 119 / `config.lua` 47 / `init.lua` 18），其中真正要复用的是
> 「日期算术 + 月历网格 + 浮窗渲染」，与 todo2 的边界只有「哪天有任务」这一条。
> 依赖它反而带来三个对齐成本：`has_marks` 只有布尔（无数量/无标题/无按状态分色）、
> `extensions.lua:7` 的 `marked_days` 只增不减、单元格几何 4 列硬编码。
> dotfiles 里的 `lua/plugins/calendar.lua`、pack 目录与本地 fork 均已删除。

### 实现（todo2 内）

| 文件 | 职责 |
|------|------|
| `lua/todo2/ui/calendar/model.lua` | 纯日期算术：`days_in_month` / `grid`（周一或周日开头） / `shift_month` / `shift_day` / `today` |
| `lua/todo2/ui/calendar/service.lua` | 数据：扫描项目 TODO 文件的解析树，按两层分桶 —— 承诺层（有 `@due` / `~start`，坐标取 `due or start`）与活动层（无日期，坐标取 `content_updated or updated or created`）；带缓存 + `invalidate()` |
| `lua/todo2/ui/calendar/view.lua` | 浮窗：月历网格（不用任何框线字符：每格 = 一块背景色矩形，格间 1 列空白 + 周间 1 行空白分隔；每格 2 行 = 日期+计数 / 最紧急任务标题 ▎色条；忙碌度三档底色深浅、今天日期强调色块、选中日整格亮底；`●N` 未完成绿 / `○N` 已完成灰，0 不显示，>9 记 `9+`；小屏降级 compact 单行版式）、当日任务列表、右侧当日面板（列宽 ≥ 116 时启用）、双层视图与跳转、内容自适应尺寸 + 居中（含 `VimResized`）、`todo2.core.events.on_change` 自动刷新 |
| `lua/todo2/ui/calendar/init.lua` | 公共 API：`open(opts)` / `close()` / `is_open()` |
| `plugin/todo2.lua` + `commands.lua` | `:TodoCalendar [YYYY-MM] [day]` |
| `config.lua` | `calendar = { first_day_of_week, mark_icon, done_icon, winblend, show_completed }` |

### 数据流

```
TODO 文件 → render.scheduler 解析树 → service.month_entries(year, month)
   → { commits = { [day] = { entry, ... } }, activities = { ... }, undated = { entry, ... } }
   → view: 月格 ● 标记（hl 取 due.hl(due, status)）+ 当日列表（status 序 + due 序）
```

- 扫描范围：当前项目（`get_project_name()` = cwd basename）的全部 TODO 文件，因此按天查看是项目级的，不受当前 buffer 限制
- 跨文件去重：同一 id 只保留一份（与 `preview` 规则一致）
- 已完成任务保留并单独计数（`●N` 未完成 / `○N` 已完成），当日列表里灰化排在最后：「上周该交、昨天才交」仍可审计
- 归档任务（checkbox `[>]` = `archived`）不进日历，与抽屉默认一致；完成本身不清除 due
- 缓存：`service` 按 `year-month` 缓存月份条目，`invalidate()` 在 `open()` 与 store 变更回调时清空
- 布局（grid，默认）：每格 = 一块背景色矩形（不画任何边框字符），9 显示列 + 1 列空白，每周 2 行（日期+计数 / 最紧急任务标题），周间一条空行；7 列共 71 显示列。计数 `● 2` / `○ 1` 右对齐（图标与数字间留空格：`●` 宽度不定，紧贴数字会视觉重叠），日期固定在格子首列不再左右跳；忙碌度三档底色、今天 `TodoCalendarToday`、选中日 `TodoCalendarSelected`；相邻月日期变暗且不计数；尾部整周属于下个月的周裁掉
- 布局（compact，降级）：`fits_screen()` 判定放不下（含右侧面板）时退化为每周 1 行、无任务标题行，总宽同为 71
- 右侧面板：`columns >= 116` 时与月历逐行拼接（`layout.agenda = { sep_cols, segs }`），**逐行**用该行自己的字节长度定位分隔符与面板内容（含中文/圆点的行字节数 ≠ 显示列）
- 字节偏移由 `build_month_lines` 与 `layout`（`{ grid, width, rows = { { line, chip, cells } }, weeks, agenda }`）一起返回：`cells` 用 0 基字节列，`weeks` 复用 `model.grid` 的结果，渲染端不做列算术
- 文案：月历内所有可见文本为英文（项目其它文档仍中文），图标由 `calendar.mark_icon` / `calendar.done_icon` 配置
- 浮窗内屏蔽其它插件装饰：`number/relativenumber`、`signcolumn/foldcolumn/statuscolumn`、`foldenable`、`spell`、`conceallevel`，以及 `miniindentscope/minicursorword/minitrailspace/ibl/treesitter-context` 的 buffer 级开关

### 交互

| 键 | 月视图 | 日列表 |
|----|--------|--------|
| `h` / `l` | 前一天 / 后一天 | — |
| `j` / `k` | 上一周 / 下一周 | 下一条 / 上一条 |
| `t` | 回到今天 | — |
| `]m` / `[m` | 下个月 / 上个月 | — |
| `gg` | 本月 | — |
| `<CR>` | 打开当日列表 | 跳转到任务行并关闭浮窗 |
| `b` / `<BS>` / `Esc` | — | 返回月视图 |
| `q` | 关闭 | 关闭 |

### 遗留（明确不做 / 以后再说）

- 月格只显示两个计数，不显示任务标题；信息主体在当日列表
- 紧迫度（overdue / due soon）在月格里没有额外颜色区分，只影响当日列表的排序与行色
- 非当前项目、跨项目的「全部日历」视图（需要先给 `service` 加 scope 参数）
- 议程（`:TodoAgenda`，下一步 A）仍是独立浮窗；右侧当日面板只在月视图内嵌一列简要标题，尚无「点选面板项直接跳转」
- 迷你面板（drawer 顶部一行）未做；日历是独立浮窗

---

## 3. 更后面（暂不设计）

- due 带时间 `@YYYY-MM-DDTHH:MM`：等出现「按小时排程」的真实需求再说，涉及排序与时区
- 重复任务（`@every week`）：与文件内文本真相模型冲突，优先级最低
- 日历侧写回（在月历里拖动改期）：跨真实来源的写路径，风险高，需单独设计
