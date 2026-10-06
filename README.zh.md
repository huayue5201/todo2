# 📘 todo2.nvim — 代码 ↔ TODO 双向链接任务管理系统

一个面向工程师的 **代码 ↔ TODO 文件双向链接** 任务管理插件。

它让任务「归属」于代码，让 TODO 文件成为代码的自然延伸：

- **代码是任务的来源** —— 在代码行上直接创建任务，自动记录所在代码块（函数/类/方法）
- **TODO 文件是管理界面** —— 任务集中管理，支持层级、状态、归档
- **两者实时同步** —— 状态、内容、行号、上下文变更都会自动同步
- **渲染由事件驱动** —— 任何变更即时反映到界面，无需手动刷新

---

## ✨ 功能特性

### 🔗 代码 ↔ TODO 双向链接

任务同时关联两个位置：

- **代码位置**（`locations.code`）：文件路径 + 行号 + 代码块上下文
- **TODO 位置**（`locations.todo`）：TODO 文件路径 + 行号

代码文件通过 extmark 虚拟文本在关联行旁渲染任务状态；TODO 文件通过任务行管理任务。

### 🧠 代码块上下文识别

创建任务时自动识别光标所在代码块（函数/类/方法/结构体等），支持三级降级：

1. **Treesitter**（优先）
2. **LSP documentSymbol**
3. **缩进检测**（兜底）

上下文随函数重命名等重构**自动刷新**，保持标记始终锚定正确的代码块。

### ✅ 状态管理

活跃状态由用户通过 `status.cycle` 配置（见「配置」）；`completed` /
`archived` 是固定终态。

- `<CR>` 切换 完成 ↔ 未完成
- `<c-[>` 在配置的循环状态里轮换
- `<leader>mt` 打开状态选择菜单

状态轴只表达**进度**（默认 `todo` / `doing` / `blocked`）；任务类型 / 模块放到标签里
（`#fix`、`#backend`）。旧版本把 `fix` / `refactor` / `AI` 当状态用，首次启动会自动
迁移为标签（`:TodoMigrateTags` 可手动重跑）。

### 🏷️ 标签（Tags）

标签是**多值、与状态正交**的属性：同一个任务既可以处于 `todo`，又可以同时带
`#fix`、`#backend` 等标签。状态回答「任务进行到哪一步」，标签回答「任务是什么类型 / 属于哪个模块」，
两者不再相互挤占同一条轴。

- 文件里写在标记之后、内容之前：`- [ ] todo:ab12cd #fix #backend 修复登录`
- 实时渲染为 `#fix` 文本（青色斜体），编辑、搜索、`rg '#fix'` 都友好
- 标签统一小写、去重、按字典序存储（`core.tags`），改动会同时回写 TODO 文件行
- 在 TODO 文件里直接改 `#tag`，同步时也会回写存储
- 抽屉、`:TodoLinks` quickfix、`:TodoLinksBuf` location list，以及代码文件中的任务标记，都会显示标签
- MCP：`set_tags` / `add_tags` / `remove_tags` 三个写接口；`list_tasks` 支持 `tag` 过滤；
  `create_task` / `create_task_tree` 支持 `tags`
- 编辑器内：`:TodoTag` 在 **TODO 行或代码锚点**处无参数时弹出**多选菜单**（勾选/取消、新增、清空），选「应用」才写回（Esc 放弃）——
  `:TodoTag fix backend` 整体设置、`:TodoTag +urgent` 追加、`:TodoTag -bug` 删除
- `:TodoFilter fix` 只显示带指定标签的任务（保留祖先/后代作上下文）；`:TodoFilter` 或 `:TodoFilter!` 清除

### 📝 任务正文（描述）

标题只有一行；更长的说明（规格、清单，甚至一小段技术文档）写在任务行下方的
**缩进续行**里 —— 就是普通 Markdown，不需要任何额外语法：

```markdown
- [ ] todo:ab12cd 加 jar 自动更新 cookie
     需要支持：
     1. 从 config 读 jar 路径
     2. 定时刷新

     参考 `src/http_client.rs`
  - [ ] todo:34ef56 子任务（任务行会让正文结束）
```

- 比任务行**缩进更深**的非任务行即该任务的正文；允许空行 → 支持多段
- 正文缩进对齐到**显示后的任务文本**（任务缩进 + 5）；保存时自动规整（`description.format_on_save`）
- TODO 文件里正文**默认折叠**，`za` / `zR` 展开；折叠行显示 `◻ 标题  ¶ N 行`
- TODO 文件里 `:TodoDesc` 直接**内联编辑**（展开折叠、光标落到正文）；在代码文件/抽屉里用多行浮窗
- 删除任务会连同其正文一起删除（正文与任务强绑定）
- 归档会把正文一起搬到归档区
- 持久化为 `core.description`，文件仍是唯一真源

### 📦 归档

- 归档整棵任务树
- 自动创建/定位归档区域（`## Archived (YYYY-MM)`）
- 自动把 `[ ]` / `[x]` 转为 `[>]`
- 删除代码链接，绝不修改代码文件

### 🪄 行号实时追踪

代码文件发生插入/删除行时，通过 buffer `on_lines` 增量更新所有关联任务的行号，标记始终跟随代码。

代码块被整体删除（或移动后无法在本文件内定位）时，标记不会误导性地漂到别处：
代码侧停止渲染，对应 TODO 行显示 `⚠`。此时可用 `:TodoLink <id>` 重新关联到新位置，
或按 `<BS>` 删除整个任务。

### 📊 浮窗 + 实时进度条

浮窗打开 TODO 文件时，底部 footer 显示任务完成进度条；切换任务状态后进度条**实时刷新**。

### 🧭 智能跳转

`<C-,>` 在代码 ↔ TODO 之间动态跳转。

### 🔎 光标悬停（hover.nvim）

装了 [hover.nvim](https://github.com/lewis6991/hover.nvim) 时，把 `todo2.hover` 加进它的
`providers`，光标停在任务上（代码标记行 / TODO 任务行）按 `K` 就能看到任务上下文，
与 LSP / diagnostics 并列为来源，用 `[s` / `]s` 切换——不额外占键位：

```lua
require("hover").setup({
  providers = { "hover.providers.lsp", "hover.providers.diagnostic", "todo2.hover" },
})
```

### 🤖 任务上下文（供 AI）

`:TodoContext` 把当前任务的上下文组装成可喂给大模型的文本：任务内容 / 正文 / 状态、
**代码锚点**（路径、行、所在代码块 type/name/signature、源码正文）、任务树（祖先链 + 子树）。

- 默认输出 Markdown 并复制到剪贴板；`:TodoContext json` 输出 JSON，`:TodoContext!` 用 scratch 打开。
- 锚点带状态：`ok` / `stale`、`lost`（已失联，不附源码）、`inherited`（补充任务，继承自父任务）。
- 组装层 `todo2.ai` 与具体客户端解耦。

#### MCP（供 pi 等 Agent）

插件内置一个极简 MCP stdio 服务，把任务作为工具暴露给 MCP 客户端：

- 读：`list_tasks` / `get_task_tree` / `get_task_context`（标记为 readOnly）
- 写：`create_task` / `create_task_tree` / `set_status` / `set_tags` / `add_tags` / `remove_tags` / `link_code` / `create_todo_file`
- 修复：`verify_anchors`

**硬约束：`create_task` / `create_task_tree` 必须带代码锚点**（`anchor = {path,line}`，指向真实
symbol 的 1-based 行号），缺锚点的任务直接拒绝。锚点会先预检（文件存在、行号在范围内），写入后
**立即重新核验**，所以返回的锚点状态是真实状态（`ok` / `lost`）。分阶段/流水线用
`create_task_tree`，需要时用 `verify_anchors` 重新定位 stale/lost 锚点。

`create_task` 默认做**幂等/去重**：同内容 + 同父级的已有任务会被直接复用（返回 `deduped: true`），
Agent 重试不会重复建；确实要重复建时传 `allow_duplicate: true`。

桥进程会连回**活着的 nvim**（单一真源），不直接读 store 快照。

跑 `:TodoMcp` 会打印接入命令，形如：

```bash
pi mcp add todo2 --env TODO2_NVIM=<socket> -- nvim --headless -u NONE -l <plugin>/mcp/todo2-mcp.lua
```

建议在 `~/.pi/agent/mcp.json` 的 `todo2` 条目里加 `"exposure": "direct"`，让模型直接看到这些工具。

### 📁 可配置的 TODO 文件识别

默认识别 `.todo.md` / `.todo` / `.todo.txt` / `todo.txt`，可通过配置扩展任意扩展名。

---

## 🚀 安装

依赖：**[nvim-store3](https://github.com/yourname/nvim-store3)**（持久化存储）。

使用 lazy.nvim：

```lua
{
    "huayue5201/todo2",
    dependencies = { "nvim-store3" },
}
```

懒加载已由插件端处理：`plugin/todo2.lua` 只注册命令 / 全局键 / TODO 文件
检测，真正的初始化（`require("todo2").setup()`）在**首次打开 TODO 文件或使用
命令/键位**时才执行。因此无需配置 `lazy` / `config` / `event`。

---

## ⚙️ 配置

所有配置项均为**顶层键**，默认值如下。请在 `init.lua` 中（插件加载前）
设置：

```lua
vim.g.todo2_config = {
    -- 核心
    conceal_enable = true,

    -- 循环（活跃）状态：顺序即循环顺序，第一个为默认状态。
    -- label 同时是 TODO 文件里的标记前缀，已有任务后改名会让标记失联。
    status = {
        cycle = {
            { label = "todo", icon = " ", color = "#51cf66" },
            { label = "doing", icon = "▶ ", color = "#4dabf7" },
            { label = "blocked", icon = "⛔ ", color = "#ff6b6b" },
        },
    },

    -- 任务正文（任务行下方的缩进续行）
    description = {
        fold = true, -- 在 TODO 文件里默认折叠正文
    },

    -- 代码文件里的任务渲染位置
    code_render = {
        position = "inline", -- "inline"（行内/行尾）| "above"（当前行上方）
    },

    -- 解析器
    parser = {
        indent_width = 2,
        empty_line_reset = 1,
        context_split = false,
    },

    -- 进度条样式
    progress_bar = {
        style = "full",
        chars = {
            filled = "▰",
            empty = "▱",
            separator = " ",
        },
        length = { min = 5, max = 20 },
        highlights = {
            done = "Todo2ProgressDone",
            todo = "Todo2ProgressTodo",
        },
    },

    -- 复选框图标
    checkbox_icons = {
        todo = "◻",
        done = "✔",
        archived = "📦",
    },

    -- 视图树缩进图标
    viewer_icons = {
        indent = {
            top    = "│ ",
            middle = "├─",
            last   = "└─",
            ws     = "  ",
        },
    },

    -- 视图（viewer）显示配置
    viewer_show_icons = true,
    viewer_show_child_count = true,
    viewer_file_header_style = "─ %s ──[ %d tasks ]",

    -- 任务树抽屉（:TodoDrawer）
    drawer = {
        position = "right",     -- "right" | "bottom"（上下拆分可展示更多）
        width = 40,             -- position = "right" 时的宽度
        height = 12,            -- position = "bottom" 时的高度
        focus_on_jump = false,  -- true 时 <CR> 跳转后焦点跟随到代码窗口
    },

    -- 状态图标
    status_icons = {
        normal    = { icon = "", color = "#51cf66", label = "正常" },
        urgent    = { icon = "󰚰", color = "#ff6b6b", label = "紧急" },
        waiting   = { icon = "󱫖", color = "#ffd43b", label = "等待" },
        completed = { icon = "", color = "#868e96", label = "完成" },
        archived  = { icon = "📦", color = "#868e96", label = "归档" },
    },

    -- 归档区域标题前缀
    archive_section = {
        title_prefix = "## Archived",
    },

    -- TODO 文件识别（可扩展任意格式）
    todo_files = {
        extensions = { ".todo.md", ".todo", ".todo.txt" }, -- 后缀匹配
        filenames  = { "todo.txt" },                        -- 精确文件名
        globs      = { "*.todo.md", "*.todo", "*.todo.txt", "todo.txt" },
        default_ext = ".todo.md",                           -- 新建默认后缀
    },

    -- 新文件模板
    file_template = {
        default_content = { "## Active" },
    },
}
```

> 提示：配置文件持久化在 `.todo2/config.json`（通过 `config.update` 写入）。

---

## ⌨️ 按键

保留少量核心智能键（在 TODO / 代码文件上下文生效，否则回退默认行为）：

| 按键 | 功能 |
|------|------|
| `<CR>` | 切换任务状态 |
| `<BS>` | 智能删除任务 |
| `<c-[>` | 循环切换状态 |
| `<S-CR>` | 从代码编辑任务内容 |
| `<C-,>` | 动态跳转 TODO ↔ 代码 |

### 任务树抽屉

`:TodoDrawer`（右侧面板）有独立的键位：

| 按键 | 功能 |
|------|------|
| `<CR>` | 切换任务状态 |
| `<S-CR>` | 循环切换活跃状态 |
| `t` | 选择任务状态（菜单） |
| `T` | 编辑标签（多选菜单） |
| `<Tab>` | 跳到任务位置：有代码锚点去代码，纯任务 / 失联去 TODO 行 |
| `o` | 浮窗预览 TODO 文件 |
| `e` | 编辑任务内容 |
| `E` | 编辑任务正文（描述） |
| `y` | 复制当前任务上下文（Markdown，供 AI） |
| `<BS>` | 删除任务 |
| `za` / `zo` / `zc` | 折叠 / 展开 / 收起当前节点 |
| `zR` / `zM` | 全部展开 / 全部收起 |
| `r` | 刷新 |
| `?` | 显示 / 关闭本帮助 |
| `q` | 关闭抽屉 |

> 抽屉里带 `↗` 的任务有自己的代码锚点；`↳` 表示锚点继承自父任务（`ns` 补充任务）；纯清单任务没有标记，`<Tab>` 会打开它的 TODO 行。

其余功能通过命令暴露，由用户自行映射：

```lua
-- 示例：按需映射
vim.keymap.set("n", "<leader>mf", "<cmd>TodoFloat<cr>", { desc = "浮窗打开 TODO" })
vim.keymap.set("n", "<leader>ma", "<cmd>TodoAdd<cr>", { desc = "从代码创建任务" })
```

---

## 📋 命令

| 命令 | 功能 |
|------|------|
| `:TodoSync` | 手动同步当前 TODO 文件 |
| `:SmartPreview` | 智能预览 TODO/代码 |
| `:TodoNew` / `:TodoRename` / `:TodoDelete` | 创建 / 重命名 / 删除 TODO 文件 |
| `:TodoToggle` | 切换任务状态 |
| `:TodoCycle` | 循环切换状态 |
| `:TodoDel` | 智能删除任务 |
| `:TodoStatus` | 选择任务状态（菜单） |
| `:TodoDesc` | 编辑任务正文（描述）—— 在 TODO 文件中或关联的代码行上都可用 |
| `:TodoAdd` | 从代码创建任务 |
| `:TodoLink [id]` | 把当前代码行关联到已有任务（省略 id 则弹出选择） |
| `:TodoEditTask` | 从代码编辑任务内容 |
| `:TodoInsert` / `:TodoInsertSub` / `:TodoInsertSibling` | 新建任务 / 子任务 / 平级任务 |
| `:TodoArchive` | 归档任务组 |
| `:TodoMigrateTags` | 把旧类型状态 (fix/refactor/AI) 迁移为标签 |
| `:TodoTag [标签]` | 给光标处任务加 / 删 / 设置标签（无参数=选择菜单；`+tag` 追加、`-tag` 删除） |
| `:TodoFilter [标签]` | 只显示带指定标签的任务（`!` 清除筛选） |
| `:TodoLinks` / `:TodoLinksBuf` | 显示双链标记（QuickFix / LocList） |
| `:TodoJump` | 动态跳转 TODO ↔ 代码 |
| `:TodoContext [markdown/json]` | 复制当前任务上下文（供 AI）；`!` 用 scratch 打开 |
| `:TodoMcp` | 打印 MCP 接入信息（供 pi 等客户端） |
| `:TodoFloat` / `:TodoSplit` / `:TodoVSplit` / `:TodoEdit` | 浮窗 / 水平 / 垂直 / 编辑打开 |
| `:TodoClose` | 关闭窗口 |
| `:TodoToggleSel` | 批量切换选中任务（可视模式） |
| `:TodoDrawer` | 切换任务树抽屉（右侧面板） |

---

## 📝 任务行格式

TODO 文件中的任务行格式：

```
- [ ] <status>:<id> [#tag ...] 任务内容
         可选的正文（缩进续行）
```

- 前缀支持 `- `、`* `、`+ `
- checkbox 支持 `[ ]`（未完成）、`[x]` / `[X]`（完成）、`[>]`（归档）
- `<status>` 为循环状态标签（默认 `todo` / `doing` / `blocked`）
- `<id>` 为 6 位 base36 ID
- `[#tag ...]` 为可选的**多值标签段**，紧跟在标记之后、内容之前；标签统一小写、
  去重、按字典序排列
- 比任务行**缩进更深**的非任务行属于该任务的**正文**；遇到下一个任务行
  （或缩进不够的行）结束

示例：

```
## Active
- [ ] todo:ab12cd #fix 修复登录逻辑
  - [x] todo:34ef56 处理空输入
- [ ] todo:78ab90 #backend #urgent 补充文档

## Archived (2026-09)
- [>] archived:cd34ef 已完成的任务
```

> 代码文件**不插入文本标记**，代码关联由存储（store）中的 `locations.code` 维护，通过 extmark 虚拟文本渲染。

---

## 🧩 目录结构

```
lua/todo2/
├── init.lua            # 插件入口
├── config.lua          # 配置
├── constants.lua       # 全局常量（namespace 等）
├── dependencies.lua    # 依赖检查
├── keymaps.lua         # 按键映射
├── commands.lua        # 用户命令
├── autocmds.lua        # 自动命令
├── handlers/           # 按键处理器（task / ui / link）
├── core/               # 领域逻辑
│   ├── status.lua          # 状态机与过渡
│   ├── state_manager.lua   # 状态切换
│   ├── archive.lua         # 归档业务
│   ├── archive_utils.lua   # 归档行编辑
│   ├── description.lua     # 描述扫描/追加
│   ├── migrate.lua         # 旧「类型状态」→ 标签一次性迁移
│   ├── sync.lua            # TODO 文件同步
│   ├── parser.lua          # TODO 文件解析
│   ├── code_tracker.lua    # 代码行号追踪 + 上下文刷新
│   ├── events.lua          # 事件系统
│   ├── stats.lua           # 统计
│   └── autosave.lua        # 自动保存
├── store/              # 持久化
│   ├── index.lua           # 文件 ↔ 任务索引
│   ├── nvim_store.lua      # 存储封装（nvim-store3）
│   ├── types.lua           # 类型与状态枚举
│   └── task/               # 任务数据
│       ├── core.lua            # CRUD
│       ├── query.lua           # 查询
│       ├── relation.lua        # 父子关系
│       ├── offset.lua          # 行号偏移
│       └── archive.lua         # 归档快照
├── render/             # 渲染
│   ├── scheduler.lua       # 渲染调度
│   ├── todo_render.lua     # TODO 文件渲染
│   ├── code_render.lua     # 代码文件渲染
│   ├── task_virt.lua       # 共享虚拟文本构建
│   ├── conceal.lua         # 复选框/图标 conceal
│   ├── filter.lua          # 标签筛选（隐藏不匹配行）
│   ├── progress.lua        # 进度条
│   └── highlights.lua      # 高亮
├── ui/                 # 交互组件
│   ├── window.lua          # 浮窗/分屏
│   ├── file_manager.lua    # TODO 文件管理
│   ├── status.lua          # 状态 UI（图标/菜单）
│   ├── archive.lua         # 归档 UI
│   ├── input.lua           # 输入浮窗
│   └── statistics.lua      # 统计格式化
├── task/               # 任务视图
│   ├── cursor.lua          # 光标处任务查询
│   ├── jumper.lua          # 跳转
│   ├── deleter.lua         # 删除
│   ├── preview.lua         # 预览
│   └── viewer.lua          # QuickFix/LocList 视图
├── creation/           # 创建流程
│   ├── manager.lua         # 创建会话
│   ├── service.lua         # 创建服务
│   └── actions/            # parent / child / sibling / operations
├── code_block/         # 代码块识别（独立子模块）
│   ├── engine.lua          # 引擎
│   ├── providers/          # treesitter / lsp / indent
│   └── queries/            # 语言查询配置
└── utils/              # 工具
    ├── file.lua            # 文件工具（含 TODO 文件识别）
    ├── format.lua          # 任务行解析/格式化
    ├── id.lua              # ID 生成/提取
    ├── line.lua            # 行分析
    ├── buffer.lua          # 缓冲区工具
    ├── project.lua         # 项目工具
    ├── tags.lua            # 任务标签（#fix）解析/格式化/规范化
    ├── task_line.lua       # 按 store 重写任务 TODO 行
    └── time.lua            # 时间
```

---

## 🧠 工作流示例

### 1. 从代码创建任务

1. 光标放在代码中要关联的行上
2. 按 `<leader>ma`
3. 选择 TODO 文件
4. 任务自动写入 TODO 文件，同时记录代码位置与所在代码块上下文

### 2. 在 TODO 文件中添加任务

直接在 TODO 文件里建任务，它们本身不写入代码文件：

- `<leader>np`：新建独立任务（纯清单任务，无上下文）
- `<leader>ns`：在当前任务下新建子任务（补充任务）
- `<leader>nn`：在当前任务同级新建任务

`np` / `nn` 是纯清单任务，与代码无关；`ns` 子任务没有自己的代码锚点，**上下文继承自最近的父任务**：父是纯清单任务则子也是纯清单任务，父有代码锚点则子任务的 `<Tab>` 会跳到父任务的代码。要单独关联代码，用 `:TodoLink`。

### 3. 在代码中切换任务状态

光标在代码文件中已关联任务的行上，按 `<CR>` 即可切换完成状态，代码侧的标记（extmark）立即更新。

### 4. 归档已完成任务组

在 TODO 文件中，光标放在已完成的任务组上，按 `<leader>mg`，整棵树移入归档区域。

---

## 📄 许可证

MIT License
