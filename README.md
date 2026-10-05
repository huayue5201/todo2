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

**Requirements:** Neovim 0.13+ (uses `vim.async`).
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

Active statuses are **user-configurable** (`status.cycle`, see
Configuration); `completed` / `archived` are fixed terminal states.

- `<CR>` toggles completed ↔ not completed
- `<c-[>` cycles through the configured cycle
- `<leader>mt` opens the status selection menu

### 📝 Task description (body)

A title is one line; longer notes (specs, checklists, even a small tech doc) go
on **indented continuation lines** right under the task -- plain Markdown, no
extra syntax:

```markdown
- [ ] todo:ab12cd add jar-based cookie refresh
     Needs:
     1. read the jar path from config
     2. refresh on a timer

     See `src/http_client.rs`
  - [ ] todo:34ef56 subtask (a task line ends the body)
```

- Any non-task line **indented deeper than the task** belongs to its body;
  blank lines are allowed, so multi-paragraph bodies work
- Body indentation aligns with the **rendered task text** (task indent + 5); it is
  normalized on save (`description.format_on_save`)
- Bodies are **collapsed by default** in TODO files; `za` / `zR` expand them.
  The fold shows `◻ title  ¶ N 行`
- In a TODO file `:TodoDesc` edits the body **inline** (opens the fold, moves the
  cursor into the body); in a code file or the drawer it uses a multi-line float
- Deleting a task removes its body too (body and task are strongly bound)
- Archiving moves the body with the task
- Stored as `core.description`; the file stays the source of truth

### 📦 Archiving

- Archive an entire task tree
- Automatically creates/locates the archive section (`## Archived (YYYY-MM)`)
- Automatically converts `[ ]` / `[x]` to `[>]`
- Removes the code link; never modifies code files

### 🪄 Real-time line-number tracking

When code files insert/delete lines, all linked tasks' line numbers are
updated incrementally via buffer `on_lines`, so markers always follow the
code.

When a code block is deleted outright (or moved and can no longer be located),
the marker does not drift to an unrelated line: it stops rendering in the code
buffer and the TODO line shows `⚠`. Re-link it with `:TodoLink <id>`, or delete
the whole task with `<BS>`.

### 📊 Floating window + live progress bar

Opening a TODO file in a floating window shows a task completion progress bar
in the footer; it refreshes in real time when task statuses change.

### 🧭 Smart jump

`<s-tab>` dynamically jumps between code ↔ TODO.

### 🔎 Hover (hover.nvim)

With [hover.nvim](https://github.com/lewis6991/hover.nvim), add `todo2.hover` to its
`providers` and pressing `K` on a task (a code marker line or a TODO task line) shows
the task context alongside LSP / diagnostics as a switchable source (`[s` / `]s`) --
no extra keymap:

```lua
require("hover").setup({
  providers = { "hover.providers.lsp", "hover.providers.diagnostic", "todo2.hover" },
})
```

### 🤖 Task context (for AI)

`:TodoContext` assembles the current task into text you can feed to an LLM:
task content / description / status, the **code anchor** (path, line, the code
block's type/name/signature and its source), and the task tree (ancestor chain +
subtasks).

- Markdown to the clipboard by default; `:TodoContext json` emits JSON, `:TodoContext!` opens it in a scratch buffer.
- The anchor carries a state: `ok` / `stale`, `lost` (no source attached), `inherited` (a supplement inheriting from its parent).
- The assembly layer `todo2.ai` is client-agnostic.

#### MCP (for pi and other agents)

The plugin ships a minimal MCP stdio server exposing the tasks as tools:

- Read: `list_tasks` / `get_task_tree` / `get_task_context` (marked readOnly)
- Write: `create_task` / `set_status` / `link_code`

`create_task` is **idempotent** by default: a task with the same content under the
same parent is reused (returns `deduped: true`), so agent retries don't duplicate.
Pass `allow_duplicate: true` to force creation.

The bridge connects back to the **live Neovim** (single source of truth) instead of
reading store snapshots.

Run `:TodoMcp` to print the setup command, e.g.:

```bash
pi mcp add todo2 --env TODO2_NVIM=<socket> -- nvim --headless -u NONE -l <plugin>/mcp/todo2-mcp.lua
```

Setting `"exposure": "direct"` on the `todo2` entry in `~/.pi/agent/mcp.json` makes the model see the tools directly.

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

    -- Checkbox icons
    checkbox_icons = {
        todo = "◻",
        done = "✔",
        archived = "📦",
    },

    -- Viewer tree indent icons
    viewer_icons = {
        indent = {
            top    = "│ ",
            middle = "├─",
            last   = "└─",
            ws     = "  ",
        },
    },

    -- Viewer display options
    viewer_show_icons = true,
    viewer_show_child_count = true,
    viewer_file_header_style = "─ %s ──[ %d tasks ]",

    -- Task-tree drawer (:TodoDrawer)
    drawer = {
        position = "right",     -- "right" | "bottom"
        width = 40,             -- width when position = "right"
        height = 12,            -- height when position = "bottom"
        focus_on_jump = false,  -- true: move focus to code after <CR>
    },

    -- Status icons
    status_icons = {
        normal    = { icon = "", color = "#51cf66", label = "正常" },
        urgent    = { icon = "󰚰", color = "#ff6b6b", label = "紧急" },
        waiting   = { icon = "󱫖", color = "#ffd43b", label = "等待" },
        completed = { icon = "", color = "#868e96", label = "完成" },
        archived  = { icon = "📦", color = "#868e96", label = "归档" },
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

### Task-tree drawer

`:TodoDrawer` (right-hand panel) has its own keys:

| Key | Action |
|------|--------|
| `<CR>` | Toggle task status |
| `<S-CR>` | Cycle status |
| `t` | Select task status (menu) |
| `<Tab>` | Jump to the task's location: linked code, or its TODO line for pure/lost tasks |
| `o` | Preview the TODO file in a float |
| `e` | Edit task content |
| `E` | Edit task description (body) |
| `y` | Copy the current task's context (Markdown, for AI) |
| `<BS>` | Delete task |
| `za` / `zo` / `zc` | Fold / unfold / collapse the current node |
| `zR` / `zM` | Expand / collapse all |
| `r` | Refresh |
| `?` | Toggle this help |
| `q` | Close the drawer |

> Tasks marked `↗` have their own code anchor. `↳` means the anchor is inherited from the parent (`ns` supplements). Plain tasks have no marker; `<Tab>` opens their TODO line.

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
| `:SmartPreview` | Smart-preview TODO/code |
| `:TodoNew` / `:TodoRename` / `:TodoDelete` | Create / rename / delete TODO file |
| `:TodoToggle` | Toggle task status |
| `:TodoCycle` | Cycle status (normal → urgent → waiting) |
| `:TodoDel` | Smart-delete a task |
| `:TodoStatus` | Select task status (menu) |
| `:TodoDesc` | Edit the task description (body) -- works in a TODO file, or on a code line linked to a task |
| `:TodoAdd` | Create a task from code |
| `:TodoLink [id]` | Bind the current code line to an existing task (omit `id` to pick) |
| `:TodoEditTask` | Edit the linked TODO task content from code |
| `:TodoInsert` / `:TodoInsertSub` / `:TodoInsertSibling` | New task / subtask / sibling |
| `:TodoArchive` | Archive task group |
| `:TodoLinks` / `:TodoLinksBuf` | Show links (QuickFix / LocList) |
| `:TodoJump` | Dynamic jump TODO ↔ code |
| `:TodoContext [markdown/json]` | Copy the current task's context (for AI); `!` opens it in a scratch buffer |
| `:TodoMcp` | Print MCP setup info (for pi and other clients) |
| `:TodoFloat` / `:TodoSplit` / `:TodoVSplit` / `:TodoEdit` | Open TODO (float / hsplit / vsplit / edit) |
| `:TodoClose` | Close window |
| `:TodoToggleSel` | Batch-toggle selected tasks (visual mode) |
| `:TodoDrawer` | Toggle the task-tree drawer (right panel) |

---

## 📝 Task line format

Task lines in TODO files use this format:

```
- [ ] <status>:<id> task content
         optional description (indented continuation lines)
```

- Prefixes `- `, `* ` and `+ ` are supported
- Checkboxes: `[ ]` (todo), `[x]` / `[X]` (done), `[>]` (archived)
- `<status>` is a cycle label (`todo` / `fix` / `refactor` by default)
- `<id>` is a 6-character base36 ID
- Lines indented deeper than a task line form its **description**; they end at
  the next task line (or at a line that is not indented deeper)

Example:

```
## Active
- [ ] :ref:ab12cd fix login logic
  - [x] :ref:34ef56 handle empty input
- [ ] :ref:78ab90 add documentation

## Archived (2026-09)
- [>] :ref:cd34ef completed task
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

### 2. Add a task in a TODO file

Tasks added directly in the TODO file do not write to code files:

- `<leader>np`: new independent task (a plain checklist task, no context)
- `<leader>ns`: new subtask of the current task (a supplement)
- `<leader>nn`: new sibling of the current task

`np` / `nn` are plain checklist tasks unrelated to code. An `ns` subtask has no
code anchor of its own and **inherits the context of its nearest ancestor**:
under a plain parent it is plain too; under an anchored parent its `<Tab>`
jumps to the parent's code. Use `:TodoLink` to attach code explicitly.

### 3. Toggle task status in code

With the cursor on a linked line in a code file, press `<CR>` to toggle the
completed status; the code-side marker (extmark) updates immediately.

### 4. Archive a completed task group

In a TODO file, place the cursor on a completed task group and press
`<leader>mg`; the whole tree moves to the archive section. Press `<leader>mu`
to undo.

---

## 📄 License

MIT License
