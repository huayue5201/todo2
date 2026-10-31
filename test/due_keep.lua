-- 到期日不得在「编辑内容 / 归档-反归档」时丢失（回归测试，headless 自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-due-keep-xdg nvim --headless -u NONE -l test/due_keep.lua
--
-- 背景：format.format_task_line 需要显式传 due，两处调用点曾漏传且直接写盘，
-- 导致编辑任务内容或归档搬段后 `@YYYY-MM-DD` 从 TODO 行消失（store 里还在，
-- 下次 reconcile 以文件为准 → due 真丢）。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-due-keep-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
local tododir = vim.fn.expand("~/.todo-files/todo2-due-keep-proj")
vim.fn.delete(tododir, "rf")

require("todo2").setup({})

local actions = require("todo2.ai.actions")
local core = require("todo2.store.task.core")
local archive = require("todo2.core.archive")
local handlers_task = require("todo2.handlers.task")
local input_ui = require("todo2.ui.input")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local due = "2031-03-04"
local start = "2031-03-01"
local f = actions.create_todo_file("duekeep")
local a = actions.create_task({ content = "带到期日的任务", path = f.path })
check("create", a and a.id)
actions.set_due(a.id, due)
require("todo2.handlers.datefield").set_by_id("start", a.id, start)

local function line_of(id)
	local loc = core.get_todo_location(id)
	if not loc then
		return nil
	end
	return vim.fn.readfile(loc.path)[loc.line]
end

check("due written to the file", (line_of(a.id) or ""):find("@" .. due, 1, true) ~= nil, line_of(a.id))
check("start written to the file", (line_of(a.id) or ""):find("~" .. start, 1, true) ~= nil, line_of(a.id))

---------------------------------------------------------------------
-- 1) 编辑内容：行上必须保住 @due
---------------------------------------------------------------------
vim.cmd("edit " .. vim.fn.fnameescape(f.path))
vim.wait(300, function()
	return false
end)
local loc = core.get_todo_location(a.id)
vim.api.nvim_win_set_cursor(0, { loc.line, 0 })

local real_prompt = input_ui.prompt_multiline
input_ui.prompt_multiline = function(_, cb)
	cb("改过之后的内容")
end
handlers_task.edit_task_by_id(a.id)
input_ui.prompt_multiline = real_prompt
vim.wait(300, function()
	return false
end)

local edited = line_of(a.id) or ""
check("edit keeps the due date", edited:find("@" .. due, 1, true) ~= nil, edited)
check("edit keeps the start date", edited:find("~" .. start, 1, true) ~= nil, edited)
check("edit applied the new content", edited:find("改过之后的内容", 1, true) ~= nil, edited)

---------------------------------------------------------------------
-- 2) 归档 → 归档段里的行必须带 @due；反归档后 due 还在
---------------------------------------------------------------------
check("archive call", archive.archive_task_group(a.id) == true)
-- 归档段仍写在同一个 TODO 文件里（追加到最后一个归档段）；
-- apply_changes 直接改缓冲区，磁盘等 autosave，所以这里读缓冲区
local archived_lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
-- 归档行的标记前缀随状态变（`archived:<id>`），不是 `todo:<id>`
local archived_entry = archived_lines:match("- %[>%] archived:" .. a.id .. "[^\n]*") or ""
check("archive keeps the due date", archived_entry:find("@" .. due, 1, true) ~= nil, "[" .. archived_entry .. "] full: " .. archived_lines)
check("archive keeps the start date", archived_entry:find("~" .. start, 1, true) ~= nil, "[" .. archived_entry .. "]")

check("unarchive call", archive.unarchive_task_group({ a.id }) == true)
local restored = line_of(a.id) or ""
check("unarchive keeps the due date", restored:find("@" .. due, 1, true) ~= nil, restored)
check("store still has the due date", (core.get_task(a.id).core.due) == due, core.get_task(a.id).core.due)
check("store still has the start date", (core.get_task(a.id).core.start) == start, core.get_task(a.id).core.start)

vim.fn.delete(tododir, "rf")
vim.fn.delete(projdir, "rf")
print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
