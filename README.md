# 📘 todo2.nvim — Code ↔ TODO bidirectional task management

An engineer-oriented task management plugin with **bidirectional links
between code and TODO files**.

It makes tasks "belong" to code, turning TODO files into a natural extension
of your codebase:

- **Code is the source of tasks** — create tasks directly on code lines, with
  the enclosing code block (function/class/method) recorded automatically
- **TODO files are the management UI** — tasks are managed centrally, with
  hierarchy, status and archiving
- **Both stay in sync** — status, content, line numbers and context changes
  are synchronized automatically
- **Event-driven rendering** — every change is reflected immediately, no
  manual refresh needed

---

## ✨ Features

### 🔗 Code ↔ TODO bidirectional links

Each task is linked to two locations:

- **Code location** (`locations.code`): file path + line number + code-block
  context
- **TODO location** (`locations.todo`): TODO file path + line number

Code files render task status next to the linked line via extmark virtual
text; TODO files manage tasks through task lines.

### 🧠 Code-block context detection

When creating a task, the enclosing code block (function/class/method/struct,
etc.) is detected automatically, with three fallback levels:

1. **Treesitter** (preferred)
2. **LSP documentSymbol**
3. **Indent detection** (last resort)

Context refreshes automatically on refactors such as function renames, keeping
markers anchored to the correct code block.

### ✅ Status management

5 statuses are supported:

| Status | checkbox | Description |
|--------|----------|-------------|
| `normal` | `[ ]` | Normal |
| `urgent` | `[ ]` | Urgent |
| `waiting` | `[ ]` | Waiting |
| `completed` | `[x]` | Completed |
| `archived` | `[>]` | Archived |

- `<CR>` toggles completed ↔ not completed
- `<c-[>` cycles normal → urgent → waiting
- `<leader>mt` opens the status selection menu

### 📦 Reversible archiving

- Archive an entire task tree
- Automatically creates/locates the archive section (`## Archived (YYYY-MM)`)
- Automatically converts `[ ]` / `[x]` to `[>]`
- Saves a full snapshot (including code context)
- One-key undo restores status, line numbers and code links completely

### 🪄 Real-time line-number tracking

When code files insert/delete lines, all linked tasks' line numbers are
updated incrementally via buffer `on_lines`, so markers always follow the
code.

### 📊 Floating window + live progress bar

Opening a TODO file in a floating window shows a task completion progress bar
in the footer; it refreshes in real time when task statuses change.

### 🧭 Smart jump

`<s-tab>` dynamically jumps between code ↔ TODO.

### 🔥 Heatmap

`Todo2Heatmap` opens a GitHub-style task status heatmap.

### 🏷️ Multi-tag system

`TODO` / `FIX` / `NOTE` / `TEST` / `COMMENT` are supported by default; tags,
icons and colors are customizable.

### 📁 Configurable TODO file detection

`.todo.md` / `.todo` / `.todo.txt` / `todo.txt` are recognized by default;
any extension can be added through configuration.

---

## 🚀 Installation

Dependency: **[nvim-store3](https://github.com/yourname/nvim-store3)**
(persistent storage).

With lazy.nvim:

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

## ⚙️ Configuration

All options are **top-level keys**. Defaults. Set them in your `init.lua`
(before the plugin loads):

```lua
vim.g.todo2_config = {
    -- Core
    show_status = true,
    conceal_enable = true,

    -- Parser
    parser = {
        indent_width = 2,
        empty_line_reset = 1,
        context_split = false,
    },

    -- Progress bar style
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

    -- Tags (extensible)
    tags = {
        TODO    = { icon = " " },
        FIX     = { icon = "󰁨 " },
        NOTE    = { icon = "󱓩 " },
        TEST    = { icon = "󰇉 " },
        COMMENT = { icon = " " },
    },

    -- Checkbox icons
    checkbox_icons = {
        todo = "◻",
        done = "✔",
        archived = "📦",
    },

    -- Status icons
    status_icons = {
        normal    = { icon = "", color = "#51cf66", label = "正常" },
        urgent    = { icon = "󰚰", color = "#ff6b6b", label = "紧急" },
        waiting   = { icon = "󱫖", color = "#ffd43b", label = "等待" },
        completed = { icon = "", color = "#868e96", label = "完成" },
    },

    -- Archive section title prefix
    archive_section = {
        title_prefix = "## Archived",
    },

    -- TODO file detection (extensible to any format)
    todo_files = {
        extensions = { ".todo.md", ".todo", ".todo.txt" }, -- suffix match
        filenames  = { "todo.txt" },                        -- exact filename
        globs      = { "*.todo.md", "*.todo", "*.todo.txt", "todo.txt" },
        default_ext = ".todo.md",                           -- default for new files
    },

    -- New-file template
    file_template = {
        default_content = { "## Active" },
    },
}
```

> Tip: the configuration is persisted in `.todo2/config.json` (written via
> `config.update`).

---

## ⌨️ Keymaps

保留少量核心智能键（在 TODO / 代码文件上下文生效，否则回退默认行为）：

| Key | Action |
|------|--------|
| `<CR>` | Toggle task status |
| `<BS>` | Smart-delete a task |
| `<c-[>` | Cycle status |
| `<S-CR>` | Edit the linked TODO task content from code |
| `<s-tab>` | Dynamic jump TODO ↔ code |

其余功能通过命令暴露，由用户自行映射：

```lua
-- examples
vim.keymap.set("n", "<leader>mf", "<cmd>TodoFloat<cr>", { desc = "浮窗打开 TODO" })
vim.keymap.set("n", "<leader>ma", "<cmd>TodoAdd<cr>", { desc = "从代码创建任务" })
```

---

## 📋 Commands

| Command | Action |
|---------|--------|
| `:TodoSync` | Manually sync the current TODO file |
| `:Todo2Heatmap` | Open the task status heatmap |
| `:SmartPreview` | Smart-preview TODO/code |
| `:TodoNew` / `:TodoRename` / `:TodoDelete` | Create / rename / delete TODO file |
| `:TodoToggle` | Toggle task status |
| `:TodoCycle` | Cycle status (normal → urgent → waiting) |
| `:TodoDel` | Smart-delete a task |
| `:TodoStatus` | Select task status (menu) |
| `:TodoAdd` | Create a task from code |
| `:TodoEditTask` | Edit the linked TODO task content from code |
| `:TodoInsert` / `:TodoInsertSub` / `:TodoInsertSibling` | New task / subtask / sibling |
| `:TodoArchive` / `:TodoRestore` | Archive / restore task group |
| `:TodoLinks` / `:TodoLinksBuf` | Show links (QuickFix / LocList) |
| `:TodoJump` | Dynamic jump TODO ↔ code |
| `:TodoFloat` / `:TodoSplit` / `:TodoVSplit` / `:TodoEdit` | Open TODO (float / hsplit / vsplit / edit) |
| `:TodoClose` | Close window |
| `:TodoToggleSel` | Batch-toggle selected tasks (visual mode) |

---

## 📝 Task line format

Task lines in TODO files use this format:

```
- [ ] TAG:ref:<id> task content
```

- Prefixes `- `, `* ` and `+ ` are supported
- Checkboxes: `[ ]` (todo), `[x]` / `[X]` (done), `[>]` (archived)
- `TAG` is a tag such as `TODO` or `FIX`; `<id>` is a 6-digit hex ID

Example:

```
## Active
- [ ] TODO:ref:ab12cd fix login logic
  - [x] FIX:ref:34ef56 handle empty input
- [ ] NOTE:ref:78ab90 add documentation

## Archived (2026-09)
- [>] TODO:ref:cd34ef completed task
```

> No text markers are inserted into code files; code links are maintained in
> the store's `locations.code` and rendered through extmark virtual text.

---

## 🧩 Directory layout

```
lua/todo2/
├── init.lua            # plugin entry
├── config.lua          # configuration
├── constants.lua       # global constants (namespace, etc.)
├── dependencies.lua    # dependency checks
├── keymaps.lua         # keymaps
├── commands.lua        # user commands
├── autocmds.lua        # autocommands
├── handlers/           # key handlers (task / ui / link)
├── core/               # domain logic
│   ├── status.lua          # state machine & transitions
│   ├── state_manager.lua   # state switching
│   ├── archive.lua         # archive business logic
│   ├── archive_editor.lua  # archive line editing
│   ├── sync.lua            # TODO file sync
│   ├── parser.lua          # TODO file parsing
│   ├── code_tracker.lua    # code line tracking + context refresh
│   ├── events.lua          # event system
│   ├── stats.lua           # statistics
│   └── autosave.lua        # autosave
├── store/              # persistence
│   ├── index.lua           # file ↔ task index
│   ├── nvim_store.lua      # storage wrapper (nvim-store3)
│   ├── types.lua           # types & status enums
│   └── task/               # task data
│       ├── core.lua            # CRUD
│       ├── query.lua           # queries
│       ├── relation.lua        # parent/child relations
│       ├── offset.lua          # line-number offsets
│       └── archive.lua         # archive snapshots
├── render/             # rendering
│   ├── scheduler.lua       # render scheduling
│   ├── todo_render.lua     # TODO file rendering
│   ├── code_render.lua     # code file rendering
│   ├── task_virt.lua       # shared virtual text builder
│   ├── conceal.lua         # checkbox/icon conceal
│   ├── progress.lua        # progress bar
│   └── highlights.lua      # highlights
├── ui/                 # interactive components
│   ├── window.lua          # floating window / split
│   ├── file_manager.lua    # TODO file management
│   ├── status.lua          # status UI (icons/menu)
│   ├── archive.lua         # archive UI
│   ├── heatmap.lua         # heatmap
│   ├── input.lua           # input popup
│   └── statistics.lua      # statistics formatting
├── task/               # task views
│   ├── cursor.lua          # task under cursor
│   ├── jumper.lua          # jumping
│   ├── deleter.lua         # deletion
│   ├── preview.lua         # preview
│   └── viewer.lua          # QuickFix/LocList views
├── creation/           # creation flow
│   ├── manager.lua         # creation session
│   ├── service.lua         # creation service
│   └── actions/            # parent / child / sibling / operations
├── code_block/         # code block detection (standalone submodule)
│   ├── engine.lua          # engine
│   ├── providers/          # treesitter / lsp / indent
│   └── queries/            # language query configs
└── utils/              # utilities
    ├── file.lua            # file utils (incl. TODO file detection)
    ├── format.lua          # task line parse/format
    ├── id.lua              # ID generation/extraction
    ├── line.lua            # line analysis
    ├── buffer.lua          # buffer utils
    ├── project.lua         # project utils
    ├── hash.lua            # hashing
    └── time.lua            # time
```

---

## 🧠 Workflow examples

### 1. Create a task from code

1. Put the cursor on the code line to link
2. Press `<leader>ma`
3. Choose a tag → choose a TODO file
4. The task is written to the TODO file, with the code location and enclosing
   code-block context recorded

### 2. Toggle task status in code

With the cursor on a linked line in a code file, press `<CR>` to toggle the
completed status; the code-side marker (extmark) updates immediately.

### 3. Archive a completed task group

In a TODO file, place the cursor on a completed task group and press
`<leader>mg`; the whole tree moves to the archive section. Press `<leader>mu`
to undo.

---

## 📄 License

MIT License
