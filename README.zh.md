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
- TODO 文件里正文**默认折叠**，`za` / `zR` 展开；折叠行显示 `◻ 标题  ¶ N 行`
- `:TodoDesc` 用多行浮窗编辑正文；在 TODO 文件或关联的代码行上都能用
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

### 📊 浮窗 + 实时进度条

浮窗打开 TODO 文件时，底部 footer 显示任务完成进度条；切换任务状态后进度条**实时刷新**。

### 🧭 智能跳转

`<s-tab>` 在代码 ↔ TODO 之间动态跳转。

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
            { label = "fix", icon = "󱁤 ", color = "#ff6b6b" },
            { label = "refactor", icon = "󱑟 ", color = "#ffd43b" },
        },
    },

    -- 任务正文（任务行下方的缩进续行）
    description = {
        fold = true, -- 在 TODO 文件里默认折叠正文
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
| `<s-tab>` | 动态跳转 TODO ↔ 代码 |

### 任务树抽屉

`:TodoDrawer`（右侧面板）有独立的键位：

| 按键 | 功能 |
|------|------|
| `<CR>` | 切换任务状态 |
| `<S-CR>` | 循环切换活跃状态 |
| `t` | 选择任务状态（菜单） |
| `<Tab>` | 跳转到关联的代码位置 |
| `o` | 浮窗预览 TODO 文件 |
| `e` | 编辑任务内容 |
| `E` | 编辑任务正文（描述） |
| `<BS>` | 删除任务 |
| `za` / `zo` / `zc` | 折叠 / 展开 / 收起当前节点 |
| `zR` / `zM` | 全部展开 / 全部收起 |
| `r` | 刷新 |
| `?` | 显示 / 关闭本帮助 |
| `q` | 关闭抽屉 |

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
| `:TodoLinks` / `:TodoLinksBuf` | 显示双链标记（QuickFix / LocList） |
| `:TodoJump` | 动态跳转 TODO ↔ 代码 |
| `:TodoFloat` / `:TodoSplit` / `:TodoVSplit` / `:TodoEdit` | 浮窗 / 水平 / 垂直 / 编辑打开 |
| `:TodoClose` | 关闭窗口 |
| `:TodoToggleSel` | 批量切换选中任务（可视模式） |
| `:TodoDrawer` | 切换任务树抽屉（右侧面板） |

---

## 📝 任务行格式

TODO 文件中的任务行格式：

```
- [ ] <status>:<id> 任务内容
         可选的正文（缩进续行）
```

- 前缀支持 `- `、`* `、`+ `
- checkbox 支持 `[ ]`（未完成）、`[x]` / `[X]`（完成）、`[>]`（归档）
- `<status>` 为循环状态标签（默认 `todo` / `fix` / `refactor`）
- `<id>` 为 6 位 base36 ID
- 比任务行**缩进更深**的非任务行属于该任务的**正文**；遇到下一个任务行
  （或缩进不够的行）结束

示例：

```
## Active
- [ ] :ref:ab12cd 修复登录逻辑
  - [x] :ref:34ef56 处理空输入
- [ ] :ref:78ab90 补充文档

## Archived (2026-09)
- [>] :ref:cd34ef 已完成的任务
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
│   ├── archive_editor.lua  # 归档行编辑
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
    ├── hash.lua            # 哈希
    └── time.lua            # 时间
```

---

## 🧠 工作流示例

### 1. 从代码创建任务

1. 光标放在代码中要关联的行上
2. 按 `<leader>ma`
3. 选择 TODO 文件
4. 任务自动写入 TODO 文件，同时记录代码位置与所在代码块上下文

### 2. 在代码中切换任务状态

光标在代码文件中已关联任务的行上，按 `<CR>` 即可切换完成状态，代码侧的标记（extmark）立即更新。

### 3. 归档已完成任务组

在 TODO 文件中，光标放在已完成的任务组上，按 `<leader>mg`，整棵树移入归档区域。

---

## 📄 许可证

MIT License
