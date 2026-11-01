# 📘 todo2.nvim — Code ↔ TODO bidirectional task management

An engineer-oriented task manager that keeps a real, two-way link between your
code and your TODO files.

- **Code is the source of tasks** — create a task on a code line; the enclosing
  function/class/method is recorded automatically.
- **TODO files are the UI** — hierarchy, status, tags, due dates and archiving.
- **Both stay in sync** — status, content, line numbers and code context follow
  refactors automatically; rendering is event-driven, no refresh.
- **Tasks belong to code** — jump from a task to its code line and back, with
  markers rendered next to the linked code.

**Requirements:** Neovim 0.13+ and [nvim-store3](https://github.com/huayue5201/nvim-store3).

## Two words: marker and commitment

A task is really a **marker in your code map** (`todo:<id>` + title + anchor,
optionally with a body). With no time dimension it is a bookmark with a note.
Give it a time dimension (start → due) and it becomes a **commitment** that
has to be delivered:

| start | due | shape | meaning |
|---|---|---|---|
| ✗ | ✗ | marker | bookmark with a note, no deadline |
| ✗ | ✓ | deadline | done by the due date |
| ✓ | ✓ | interval | start → due |
| ✓ | ✗ | planned | intended for the start date |

That is why the calendar has **two layers**: `●` commitments land on their due
date (or start date when there is none), `○` marks touched land on the day they
were last modified — one day can have both (`●2 · ○3`). See `:h todo2-concepts`.

## It is not

- a general GTD or calendar app — calendars and dates exist only for code tasks;
- a cloud service — no account, no sync server, everything lives in your repo;
- a cross-project kanban — the unit is the project you are editing;
- a replacement for issue trackers — it tracks what *you* are doing in *this*
  codebase.

## Installation

With lazy.nvim:

```lua
{
    "huayue5201/todo2",
    dependencies = { "huayue5201/nvim-store3" },
}
```

Lazy loading is handled by the plugin: commands and TODO-file detection are
registered up front, and `require("todo2").setup()` runs on first use. No
`lazy` / `config` / `event` needed.

## 30-second start

1. Put the cursor on a code line and create a task:

   ```vim
   :TodoAdd
   ```

2. Open the TODO file and see the task (with its code anchor):

   ```vim
   :TodoView float
   ```

3. Jump back and forth between code and task:

   ```vim
   :TodoJump
   ```

4. Switch status (or press `<CR>` on the task):

   ```vim
   :TodoToggle
   ```

5. Set a due date (the date panel only accepts digits, so `2-31` becomes `2-28`), then look at the month calendar:

   ```vim
   :TodoDue tomorrow
   :TodoCalendar
   ```

6. Archive the finished group (moves it to `## Archived`):

   ```vim
   :TodoArchive
   ```

## Most-used commands

| Command | Action |
|---------|--------|
| `:Todo` | Open/close the task drawer; `:Todo <sub>` = `:Todo<Sub>`; `:Todo help` |
| `:TodoAdd` | Create a task from the current code line |
| `:TodoDrawer` | Toggle the task-tree drawer |
| `:TodoToggle` | Toggle task status; with a range toggles every selected task |
| `:TodoSet` | Status + tags + start + due date in one panel (the one-stop entry) |
| `:TodoStatus[!]` | Choose a status (`!` cycles to the next one) |
| `:TodoDel` | Smart delete; supports a range, `!` deletes the subtree |
| `:TodoDue [date\|none]` | Set the due date (turns a marker into a commitment) — no argument opens the three-box date panel; `none` / `clear` / `-` clears it |
| `:TodoStart [date\|none]` | Set the start date (`~YYYY-MM-DD`, must not be after the due date); same panel and syntax |
| `:TodoTag [tags]` | Set (`+tag` / `-tag`) tags on the task |
| `:TodoFilter [conditions]` | Filter by tags / `status:` / `path:` / `due:` / `start:` / `axis:` / `scope:` (`<Tab>` completes) |
| `:TodoCalendar [YYYY-MM]` | Open the project calendar |
| `:TodoArchive` / `:TodoUnarchive` | Move a task group into/out of `## Archived` |
| `:TodoSync[!]` | Sync the current TODO file (`!` = full reconcile) |
| `:TodoContext [json]` | Copy the task context for an LLM |
| `:TodoMcp` | Print MCP setup info for agents such as pi |

Low-frequency maintenance lives in groups — `:TodoFile new|rename|delete`,
`:TodoView float|split|vsplit|edit|close|preview`, `:TodoTask rename|desc|promote`,
`:TodoGit sync|review|blame`. Those are the only names — the old flat commands
were removed.

Everything else: `:h todo2`.

## Keymaps

The plugin ships a few high-frequency smart keys (in TODO / code context, with
native fallback): `<CR>` toggle, `<S-tab>` cycle, `<BS>` smart delete
`<C-[>` jump TODO ↔ code. In editing buffers only normal-mode keys are mapped,
and each falls back to native behaviour off-task; bulk delete is the range
`:'<,'>TodoDel` (`!` for subtrees).

- Drawer: see `:h todo2-keymaps-drawer` (e.g. `i` opens the attribute panel,
  `D` / `S` set due / start, `C` picks either date from a month calendar,
  Visual `<BS>` bulk-deletes and Visual `x` bulk-archives / unarchives task
  groups — that is safe because the drawer is its own scratch buffer). A drawer key is the last letter of the matching
  global mapping: `D` here is `<leader>mtD` there — see `examples/keymaps.lua`.
- Calendar: `h`/`l` day, `j`/`k` week, `H`/`L` month, `t` today, `<CR>` day
  list, `f` filter (`axis:commit` / `axis:activity`), `q` close — full list in
  `:h todo2-keymaps-calendar`.

## FAQ

**The file does not look like the screen — where did the id and date go?**
`todo:<id>` and `@YYYY-MM-DD` are concealed in the buffer; move the cursor onto
them to reveal the raw text. Turn conceal off with `conceal_enable = false`, and
the due-date band with `conceal_due = false`.

**Is `@YYYY-MM-DD` at the end of the title a due date?**
No. A due date must follow the task marker, before the tags/content:
`- [ ] todo:ab12cd @2026-07-01 #fix fix login`. A date at the end is plain text
and rewriting that line warns instead of silently dropping it.

**How do I delete a lot of tasks at once?**
`:TodoDel` accepts a line range (`:5,9TodoDel`, or Visual `:'<,'>TodoDel`);
`:TodoDel!` also deletes the subtree; in the drawer, Visual `<BS>` deletes every
selected task with its subtree.

**What if a code anchor is lost?**
Run `:TodoDoctor` for store health, `:TodoSync!` to rebuild from the TODO
files, then `:TodoLink <id>` (or `:TodoLink` to pick) to bind the task to the
correct code line.

## Documentation

Full reference: `:h todo2` (also `:Todo help`). Source of truth for every
feature, key and option is `doc/todo2.txt`. Ready-made keymaps live in
`examples/keymaps.lua`.

## Troubleshooting

```vim
:checkhealth todo2
```

Checks Neovim version, the nvim-store3 dependency, store writability, TODO file
patterns, Treesitter parsers, LSP clients and the AI/MCP state — in one place.

## Development

```sh
make test     # 31 headless tests, each with an isolated XDG data dir
make lint     # luacheck
make check    # both
```

## 📄 License

[MIT](LICENSE)
