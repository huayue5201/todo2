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
- `<S-tab>` cycles through the configured cycle
- `<leader>mts` opens the status selection menu

Statuses express **progress only** (`todo` / `doing` / `blocked` by default). Task
type / module belongs in tags (`#fix`, `#backend`).

### 🏷️ Tags

Tags are **multi-valued and orthogonal to status**: one task can be `todo` while
carrying `#fix`, `#backend`, etc. Status answers "how far along", tags answer
"what kind / which module" -- they no longer compete for the same axis.

- Written after the marker, before the content: `- [ ] todo:ab12cd #fix #backend fix login`
- Rendered live as `#fix` text (cyan italic); friendly to editing, search, `rg '#fix'`
- Normalized to lowercase, de-duplicated, sorted (`core.tags`); edits are written back to the TODO line
- Editing `#tag` directly in the TODO file is synced back into the store
- Also shown in the drawer, `:TodoLinks` quickfix, `:TodoLinksBuf` location list, and code-file task markers
- MCP: `set_tags` / `add_tags` / `remove_tags` write tools; `list_tasks` accepts a `tag` filter;
  `create_task` / `create_task_tree` accept `tags`
- In the editor: `:TodoTag` at a TODO line or a **code anchor** opens a multi-select menu -- toggle tags, add a new
  one, clear the selection, then pick **Apply** to save (Esc discards); `:TodoTag fix backend` sets
  them, `:TodoTag +urgent` adds, `:TodoTag -bug` removes
- `:TodoFilter fix` shows only tasks carrying the given tags (ancestors/descendants are
  kept for context); `:TodoFilter` or `:TodoFilter!` clears it

### 🔀 Git integration

Turns task references in commit messages (e.g. `todo:ab12cd`) into status + metadata,
and adds a pre-commit self-check. Off by default; enable explicitly:

```lua
git = {
    enable = true,          -- master switch (:TodoGitSync! bypasses it)
    trigger = "manual",     -- manual | on_open (on_open syncs when a TODO file opens)
    show_metadata = true,   -- show the linked commit in viewer / drawer
    refs = {
        { pattern = "[Tt]odo[:：]%s*([0-9a-z]+)", status = "completed" },
    },
},
```

- `:TodoGitSync` scans from the last synced commit to HEAD, applies the refs rules, and records the commit
- Within one message the latest reference wins; only the essential `todo:<id>` rule ships by default
- `:TodoGitReview` lists tasks whose code anchors sit in dirty files (pre-commit check); pair with `:TodoFilter #git:dirty`
- `:TodoGitBlame [id]` shows the commit history of a task's code anchor
- When an anchor goes stale/lost, the last commit that touched that code is recorded and shown as `⚠ 锚点已过期（1a2b3c4 by alice）` in viewer / drawer
- Derived tags: `:TodoFilter #git:dirty`, `:TodoFilter #git:branch:main`
- MCP: `complete_by_commit` (close tasks by sha or message); works regardless of `git.enable`

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

### 📦 Archiving (cold store)

Archiving is a **move, not a discard**: the whole task tree leaves the main
store and its TODO file and is written into a separate named store
(`archive`) that is loaded on demand and unloaded again. IDs are preserved and
the operation is reversible.

- `:TodoArchive` archives the task group at the cursor (its whole subtree);
  its lines (task + body) are removed from the TODO file
- `:TodoUnarchive` picks an archived group and restores it (appends the tree
  back into its TODO file, statuses preserved)
- `:TodoArchiveView` / `:TodoArchiveQF` show the archive as a tree / a flat
  anchor list (QuickFix)
- `:TodoArchiveOpen` / `:TodoArchiveClose` load / unload the cold store
- `:TodoArchiveImport` migrates legacy `## Archived (YYYY-MM)` sections into
  the cold store
- The task-tree drawer shows archived tasks when toggled with `A`
- The code anchor is **frozen** (code files are never modified); the cached
  snapshot is re-resolved through `relocate` when needed
- `archive.allow_unfinished` (default `true`) controls whether a tree with
  active tasks may be archived

### 🪄 Real-time line-number tracking

When code files insert/delete lines, all linked tasks' line numbers are
updated incrementally via buffer `on_lines`, so markers always follow the
code.

When a code block is deleted outright (or moved and can no longer be located),
the marker does not drift to an unrelated line: it stops rendering in the code
buffer and the TODO line shows `⚠`. Re-link it with `:TodoLink <id>`, or delete
the whole task with `<BS>`.

When several tasks share the same code line, their markers render **together**
(instead of overwriting each other): `above`/`below` stack one virtual line per
task, and `inline` joins them with `│`. When a parent and its subtask share the
line, they are ordered by hierarchy: the parent (group) comes first and
descendants are indented with `└`. When too many tasks share a line, only the
most relevant one is shown with a `+N` badge; the cap is controlled by
`code_render.max_lines` (default 3). The representative prefers the group
(ancestor), otherwise `doing > todo > blocked > completed > archived`; the sign
column shows its status. Pressing `<C-,>` (or `<Tab>`) on a code line with
several tasks opens a picker to choose which one to jump to; with a single task
it jumps directly.

`<leader>mvp` (`:SmartPreview`) previews the tasks for the current code line and
**highlights all same-anchor tasks together**. If they belong to different TODO
root trees, one float is opened per tree (tiled on wide screens, cascaded on
narrow ones). When there are more trees than `preview.max_trees` (default 2),
only the first N are shown with a notice; a single tree longer than
`preview.max_tree_lines` (default 20) lines is cropped around the anchor and its
title marked with `✂`.

### 📊 Floating window + live progress bar

Opening a TODO file in a floating window shows a task completion progress bar
in the footer; it refreshes in real time when task statuses change.

### 🧭 Smart jump

`<C-,>` dynamically jumps between code ↔ TODO.

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

- Read: `list_tasks` / `get_task_tree` / `get_task_context` / `search_tasks` / `get_project_info` (marked readOnly)
- Write: `create_task` / `create_task_tree` / `create_note` / `update_content` / `set_status` / `set_tags` / `add_tags` / `remove_tags` / `link_code` / `create_todo_file` / `delete_task` / `archive_task` / `unarchive_task` / `complete_by_commit`
- Repair: `verify_anchors`

**Read side**

- `list_tasks` / `search_tasks` accept `status` / `tag` filters and `limit` / `offset`
  pagination; both can include archived tasks (`include_archived`).
- `get_task_tree` returns `{files:[{path, roots:[{id,content,status,tags,anchor?,children?}]}]}`
  (nodes carry anchors); pass `include_archived` to append the cold-store `(archived)` group.
- `get_project_info` returns the project name/dir, the TODO files with task counts, and
  active/archived totals.
- Successful calls also return `structuredContent` alongside the text payload. The
  array-returning tools (`list_tasks` / `search_tasks`) declare an MCP `outputSchema`
  and wrap their array as `structuredContent.items` (the spec requires structured
  content to be a JSON object, not an array).

**Write side**

- `create_note` creates an **anchor-less** checklist item (for notes/ideas); `create_task`
  and `create_task_tree` are for tasks that *are* about code.
- `update_content` rewrites a task's text and its TODO line.
- `delete_task` / `archive_task` / `unarchive_task` close the loop: archive moves a subtree
  into the cold store, unarchive restores it. Archived tasks must be unarchived before deletion.

**Hard rule: `create_task` / `create_task_tree` require a code anchor** (`anchor = {path,line}`
pointing at the exact 1-based line of a real symbol). `create_note` is the explicit escape hatch
for anchor-less items. Anchors are pre-checked (file exists, line in range) and **re-verified
immediately after write**, so the returned anchor state reflects reality (`ok` / `lost`). Use
`create_task_tree` for a pipeline/stage breakdown, and `verify_anchors` to re-locate
stale/lost anchors at any time.

`create_task` is **idempotent** by default: a task with the same content under the
same parent is reused (returns `deduped: true`), so agent retries don't duplicate.
Pass `allow_duplicate: true` to force creation.

The bridge connects back to the **live Neovim** (single source of truth) instead of
reading store snapshots.

Set `TODO2_MCP_READONLY=1` to run the server in read-only mode (all write tools are refused).
When several Neovim instances are open, `:TodoMcp` publishes a `project → socket` registry;
set `TODO2_PROJECT=<name>` to pin the bridge to one project's instance instead of the
last-published socket.

Run `:TodoMcp` to print the setup command, e.g.:

```bash
pi mcp add todo2 --env TODO2_NVIM=<socket> -- nvim --headless -u NONE -l <plugin>/mcp/todo2-mcp.lua
```

Add `--env TODO2_MCP_READONLY=1` for read-only, or `--env TODO2_PROJECT=<name>` to pin a project.

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
        position = "inline", -- "inline"（行内/行尾）| "above"（当前行上方，行首 󱞡）| "below"（当前行下方，行首 󱞽）
        max_lines = 3,       -- 同一代码行最多展示的任务数，超出折叠为「代表任务 + +N」
    },

    -- Smart preview (:SmartPreview)
    preview = {
        max_trees = 2,       -- when an anchor spans multiple root trees, show at most N trees
        max_tree_lines = 20, -- per tree, show at most N task lines (crop around the anchor)
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

    -- Archive section title prefix (legacy sections, migrated by :TodoArchiveImport)
    archive_section = {
        title_prefix = "## Archived",
    },

    -- Archive (cold store): archiving moves the tree into a named store,
    -- loaded on demand. See :TodoArchive / :TodoUnarchive.
    archive = {
        store_name = "archive",         -- named cold store
        allow_unfinished = true,        -- allow archiving a tree containing active tasks
        include_in_render = false,      -- drawer shows archived tasks by default
        auto_after_days = 0,            -- auto-archive fully-completed groups after N days (0 = off)
        retention_days = 0,             -- prune archived groups + tombstones older than N days (0 = keep forever)
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
| `<S-tab>` | Cycle status |
| `<S-CR>` | Edit the linked TODO task content from code |
| `<C-,>` | Dynamic jump TODO ↔ code |

### Task-tree drawer

`:TodoDrawer` (right-hand panel) has its own keys:

| Key | Action |
|------|--------|
| `<CR>` | Toggle task status |
| `<S-CR>` | Cycle status |
| `t` | Select task status (menu) |
| `T` | Edit tags (multi-select menu) |
| `f` | Filter tasks by tags (space-separated; supports `#git:dirty`, `#git:branch:main`) |
| `F` | Clear the filter |
| `<Tab>` | Jump to the task's location: linked code, or its TODO line for pure/lost tasks |
| `o` | Preview the TODO file in a float |
| `P` | Preview the task's linked code lines in a float |
| `e` | Edit task content |
| `E` | Edit task description (body) |
| `y` | Copy the current task's context (Markdown, for AI) |
| `a` | New TODO file |
| `R` | Rename the current file group's TODO file |
| `D` | Delete the current file group's TODO file (and its tasks) |
| `<BS>` | Delete task |
| `za` / `zo` / `zc` | Fold / unfold / collapse the current node |
| `zR` / `zM` | Expand / collapse all |
| `r` | Refresh |
| `A` | Toggle archived tasks in the tree |
| `?` | Toggle this help |
| `q` | Close the drawer |

> Tasks marked `↗` have their own code anchor. `↳` means the anchor is inherited from the parent (`ns` supplements). Plain tasks have no marker; `<Tab>` opens their TODO line.

> `f` prompts for one or more tags (AND); only matching tasks **and their ancestor chain** are shown, with the file header showing `(hits/total)`. The filter is drawer-local and is cleared when the drawer closes. `:TodoFilter [tags]` / `:TodoFilter!` also work while the drawer is focused.

其余功能通过命令暴露，由用户自行映射：

```lua
-- examples
vim.keymap.set("n", "<leader>mvf", "<cmd>TodoFloat<cr>", { desc = "浮窗打开 TODO" })
vim.keymap.set("n", "<leader>mta", "<cmd>TodoAdd<cr>", { desc = "从代码创建任务" })
```

---

## 📋 Commands

| Command | Action |
|---------|--------|
| `:TodoSync` | Manually sync the current TODO file |
| `:SmartPreview` | Smart-preview TODO/code |
| `:TodoNew` / `:TodoRename` / `:TodoDelete` | Create / rename / delete TODO file |
| `:TodoToggle` | Toggle task status |
| `:TodoCycle` | Cycle status |
| `:TodoDel` | Smart-delete a task |
| `:TodoStatus` | Select task status (menu) |
| `:TodoDesc` | Edit the task description (body) -- works in a TODO file, or on a code line linked to a task |
| `:TodoAdd` | Create a task from code |
| `:TodoLink [id]` | Bind the current code line to an existing task (omit `id` to pick) |
| `:TodoEditTask` | Edit the linked TODO task content from code |
| `:TodoInsert` / `:TodoInsertSub` / `:TodoInsertSibling` | New task / subtask / sibling |
| `:TodoArchive` | Archive the task group at the cursor (cold store); `!` forces a tree with unfinished tasks |
| `:TodoUnarchive` | Pick an archived group and restore it |
| `:TodoArchiveView` / `:TodoArchiveQF` | Show archived tasks as a tree / flat anchor list (QuickFix) |
| `:TodoArchiveOpen` / `:TodoArchiveClose` | Load / unload the archive store |
| `:TodoArchiveImport` | Migrate legacy `## Archived` sections into the cold store |
| `:TodoTag [tags]` | Add / remove / set tags on the cursor task (no arg = toggle menu; `+tag` add, `-tag` remove) |
| `:TodoFilter [tags]` | Show only tasks carrying the given tags (clears with `!`) |
| `:TodoGitSync` | Incrementally scan commits and apply task references (`!` ignores `enable`) |
| `:TodoGitReview` | List tasks whose code anchors are in dirty files (QuickFix) |
| `:TodoGitBlame [id]` | Show the git history of a task's code anchor |
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
- [ ] <status>:<id> [#tag ...] task content
         optional description (indented continuation lines)
```

- Prefixes `- `, `* ` and `+ ` are supported
- Checkboxes: `[ ]` (todo), `[x]` / `[X]` (done), `[>]` (archived)
- `<status>` is a cycle label (`todo` / `doing` / `blocked` by default)
- `<id>` is a 6-character base36 ID
- `[#tag ...]` is an optional **multi-value tag segment**, right after the marker and
  before the content; tags are lowercased, de-duplicated and sorted
- Lines indented deeper than a task line form its **description**; they end at
  the next task line (or at a line that is not indented deeper)

Example:

```
## Active
- [ ] todo:ab12cd #fix fix login logic
  - [x] todo:34ef56 handle empty input
- [ ] todo:78ab90 #backend #urgent add documentation

## Archived (2026-09)
- [>] archived:cd34ef completed task
```

> `[>]` and `## Archived (YYYY-MM)` sections are **legacy**: archived tasks
> now live in the cold store and are normally absent from TODO files. Legacy
> sections are still parsed (status `archived`); migrate them once with
> `:TodoArchiveImport`.

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
│   ├── archive_utils.lua   # archive line editing
│   ├── description.lua     # description scanning/appending
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
│   ├── filter.lua          # tag filter (hide non-matching lines)
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
    ├── tags.lua            # task tags (#fix): parse/format/normalize
    ├── task_line.lua       # rewrite a task's TODO line from store
    └── time.lua            # time
```

---

## 🧠 Workflow examples

### 1. Create a task from code

1. Put the cursor on the code line to link
2. Press `<leader>mta`
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

In a TODO file, place the cursor on a task group and press `<leader>maa`
(`:TodoArchive`); the whole tree moves to the cold store and leaves the file.
Press `<leader>mau` (`:TodoUnarchive`) to restore it, `<leader>mav` /
`<leader>maq` to review archived tasks, and `:TodoArchiveImport` to migrate
legacy `## Archived` sections.

---

## 📄 License

MIT License
