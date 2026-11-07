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
- **Projects can reference each other** — `@rel(...)` links a task to a task in
  another project, picked in the UI (`:TodoRel` with no argument, or `L` in the
  drawer); `:TodoGlobal` gives a read-only view of active tasks across every
  project.

**Requirements:** Neovim 0.13+ and [nvim-store3](https://github.com/huayue5201/nvim-store3).

## TODO files never live in your repo

They live in one vault, one directory per project — `~/.todo-files/<slug>--<hash8>/`,
where the hash comes from the project **identity** (its git remote, or the
absolute project root when there is no remote). Same-named projects never
collide, a moved or re-cloned repository keeps its files, and monorepo
subpackages get their own directory. Each directory carries a `.project.json`
recording identity, root and display name. See `:h todo2-projects`.

## Two words: marker and commitment

A task is really a **marker in your code map** (`@id(...)` + title + anchor,
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
- a cross-project kanban — the unit is still the project you are editing;
  `:TodoGlobal` only *reads* across projects, and a relation never writes into
  the other project (the edge lives in the source task line);
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
| `:TodoStart [date\|none]` | Set the start date (`@start(YYYY-MM-DD)`, must not be after the due date); same panel and syntax |
| `:TodoTag [tags]` | Set (`+tag` / `-tag`) tags on the task |
| `:TodoRel` | Pick tasks in other projects to relate to: `<CR>` toggles an edge, `b` switches relates/blocks (`:TodoRel project/id` for scripts) |
| `:TodoGlobal` | Toggle the read-only global view: active tasks across all projects (`f` filter, `F` clear) |
| `:TodoFilter [conditions]` | Filter by tags / `status:` / `path:` / `due:` / `start:` / `axis:` / `scope:`; `+` appends a layer (step-by-step narrowing), `-` pops, `?` shows the stack (`<Tab>` completes) |
| `:TodoQuickfix` | Snapshot the current drawer / calendar / TODO view (with its filter) into the QuickFix list (`Q` in drawer and calendar) |
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
  list, `f` filter (`+` / `-` add/remove filter layers, `axis:commit` /
  `axis:activity`), `Q` send the filtered view to QuickFix, `q` close — full
  list in `:h todo2-keymaps-calendar`.

## FAQ

**The file does not look like the screen — where did the id and date go?**
Nowhere: the metadata block (`@id`, `@created`, `@start`, `@due`, `@done`,
`@archived`, `#tag`) is plain text at the end of the line and stays visible.
Only the checkbox is concealed into a status icon. The due date is repeated,
never moved, in the **end-of-line band** next to the last-modified time
(`- [ ] fix login @due(2026-07-01)    ↻10-30 · 07-01`). Turn conceal off
with `conceal_enable = false`.

**How is the status stored?**
In the checkbox, one character per status: `[ ]` todo, `[d]` doing, `[b]`
blocked, `[x]` completed, `[>]` archived. Edit the checkbox by hand and it
sticks; the store follows the file. `status.cycle` chooses the characters.

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

## Upgrading from the pre-v2 file format

The task line used to carry the status and the id in front of the title
(`- [ ] todo:ab12cd ~2026-06-20 @2026-07-01 #fix title`). It is now plain
Markdown with a trailing metadata block
(`- [ ] title @id(ab12cd) @start(2026-06-20) @due(2026-07-01) #fix`). The
plugin parses only the new grammar, so run the one-shot migration once:

```sh
nvim --headless -u NONE -l scripts/migrate_v2.lua            # dry-run, prints the diff
nvim --headless -u NONE -l scripts/migrate_v2.lua --apply    # writes, backs up first
```

It is idempotent, keeps every touched file under
`~/.todo-files/.migrate-backup/`, and refills `@created/@done/@archived` from
the store so no timestamp is lost.

The same run also renames the project directories: they used to be named after
the project directory (`~/.todo-files/app`), and are now named after the
project identity (`~/.todo-files/app--98d9fc12`). Directories whose project is
no longer on disk are reported as `unknown` and left alone.

## Housekeeping

`:TodoDoctor` reports orphaned tasks and the project directory census
(`alive` / `gone` / `unknown` / `store-only`). A vault directory whose project
root no longer exists stays put until it has been inactive for
`projects.retention_days` days; `:TodoGc!` then moves it into
`~/.todo-files/.quarantine/` — moved, never deleted. See `:h :TodoGc`.

Two ledgers grow forever and are swept at startup once they pass
`expire.days` (default 180, `expire.enabled = false` to keep them): delete
tombstones and quarantine directories. TODO files are never expired — only the
plugin's own bookkeeping.

## Troubleshooting

```vim
:checkhealth todo2
```

Checks Neovim version, the nvim-store3 dependency, store writability, TODO file
patterns, Treesitter parsers, LSP clients, the project identity/directory, the
project directory census and (when `profile.enabled` is on) collected timings —
in one place.

If startup reconcile or the drawer feels slow, turn on `profile = { enabled =
true }` in `todo2.setup()`, use the plugin for a while, then run
`:TodoProfile` to see where the time goes.

## Development

```sh
make test     # 47 headless tests, each with an isolated XDG data dir
make lint     # luacheck
make check    # both
```

## 📄 License

[MIT](LICENSE)
