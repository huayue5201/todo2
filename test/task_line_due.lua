-- 重写任务行时的「到期日写错位置」防护测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/task_line_due.lua
--
-- 背景：到期日必须写成行尾元数据 `@due(YYYY-MM-DD)`；正文里的裸 `@2026-11-02`
-- 只是普通文本。重写该行时必须提醒，而不是静默放过。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local proj = "/tmp/todo2-task-line-due-proj"
vim.fn.delete(proj, "rf")
vim.fn.mkdir(proj, "p")
vim.fn.chdir(proj)
local dir = vim.fn.expand("~/.todo-files/todo2-task-line-due-proj")
vim.fn.delete(dir, "rf")
vim.fn.mkdir(dir, "p")
local path = dir .. "/main.todo.md"
vim.fn.writefile({ "## Active", "- [ ] 标题里带日期 @2026-11-02 @id(tl0001)" }, path)

require("todo2").setup({})
vim.cmd("edit " .. vim.fn.fnameescape(path))

local core = require("todo2.store.task.core")
local actions = require("todo2.ai.actions")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

vim.wait(3000, function()
	local ok, task = pcall(core.get_task, "tl0001")
	return ok and task ~= nil
end, 50)

local task = core.get_task("tl0001")
check("task indexed", task ~= nil)
check("trailing @date is not a due date", task == nil or task.core.due == nil, task and task.core.due)
check("trailing @date stays in the content", task ~= nil and (task.core.content or ""):find("@2026-11-02", 1, true) ~= nil)

local seen = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
	seen[#seen + 1] = { msg = tostring(msg), level = level }
end
local ok_set = pcall(actions.set_due, "tl0001", "2026-11-02")
vim.notify = orig_notify

check("set_due succeeds", ok_set)
local line = vim.fn.readfile(path)[2]
check("due date written into the metadata block", line:find(" @due%(2026%-11%-02%)$") ~= nil, line)
check("content preserved", line:find("标题里带日期", 1, true) ~= nil, line)
check("stored due matches", core.get_task("tl0001").core.due == "2026-11-02")

-- 正文以元数据形状结尾 → 会被解析掉，重写时必须提醒
seen = {}
vim.notify = function(msg, level)
	seen[#seen + 1] = { msg = tostring(msg), level = level }
end
require("todo2.utils.task_line").rewrite("tl0001", { content = "标题结尾有 @id(zzz999)" })
vim.notify = orig_notify
local stray_warned = false
for _, n in ipairs(seen) do
	if n.msg:find("tl0001", 1, true) then
		stray_warned = true
	end
end
check("rewriting warns about a meta-shaped tail", stray_warned, seen[1] and seen[1].msg)

-- 反斜杠转义的元数据形状留在正文里，不会被解析
local escaped = require("todo2.utils.format").parse_task_line("- [ ] 正文里写 \\@due(2026-01-01) @id(qq0001)")
check("escaped @due stays literal", escaped.due == nil and escaped.content:find("\\@due", 1, true) ~= nil, escaped.content)

-- 没有写错位置的日期时不该乱提醒
vim.fn.writefile({ "## Active", "- [ ] 干净的任务 @id(tl0002)" }, path)
vim.cmd("edit!")
vim.wait(3000, function()
	local ok, t = pcall(core.get_task, "tl0002")
	return ok and t ~= nil
end, 50)
seen = {}
vim.notify = function(msg, level)
	seen[#seen + 1] = { msg = tostring(msg), level = level }
end
pcall(actions.set_due, "tl0002", "2026-11-03")
vim.notify = orig_notify
local quiet = true
for _, n in ipairs(seen) do
	if n.msg:find("tl0002", 1, true) then
		quiet = false
	end
end
check("no warning for a clean task", quiet, seen[1] and seen[1].msg)

vim.fn.delete(dir, "rf")
print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
