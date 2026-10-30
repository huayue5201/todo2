-- 重写任务行时的「到期日写错位置」防护测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/task_line_due.lua
--
-- 背景：`@date` 只有紧跟在任务标记之后才会被解析成到期日；
-- 写在标题尾部只是普通文本。重写该行时必须提醒，而不是静默放过。

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
vim.fn.writefile({ "## Active", "- [ ] todo:tl0001 标题里带日期 @2026-11-02" }, path)

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
local warned = false
for _, n in ipairs(seen) do
	if n.msg:find("tl0001", 1, true) and n.msg:find("@2026-11-02", 1, true) then
		warned = true
	end
end
check("rewriting warns about the stray date", warned, seen[1] and seen[1].msg)

local line = vim.fn.readfile(path)[2]
check("due date written right after the marker", line:find("todo:tl0001 @2026%-11%-02 ") ~= nil, line)
check("content preserved", line:find("标题里带日期", 1, true) ~= nil, line)
check("stored due matches", core.get_task("tl0001").core.due == "2026-11-02")

-- 没有写错位置的日期时不该乱提醒
vim.fn.writefile({ "## Active", "- [ ] todo:tl0002 干净的任务" }, path)
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
