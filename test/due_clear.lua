-- test/due_clear.lua —— 清除到期日的四条路径（:TodoDue none/clear/-、输入框留空、MCP due:""）
-- 运行：nvim --headless -u NONE -l test/due_clear.lua

local failures = 0
local checks = 0

local function check(cond, msg)
	checks = checks + 1
	if cond then
		print("PASS " .. msg)
	else
		failures = failures + 1
		print("FAIL " .. msg)
	end
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/../nvim-store3")
vim.cmd("runtime! plugin/todo2.lua")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.cmd("cd " .. dir)
vim.fn.writefile({ "## Active", "- [ ] todo:aaa111 task one", "- [ ] todo:bbb222 task two" }, dir .. "/a.todo.md")
require("todo2").setup({ todo_files = { pattern = "*.todo.md" }, due = { panel = false } })

vim.cmd("silent! edit! " .. dir .. "/a.todo.md")
vim.cmd("TodoSync")

local core = require("todo2.store.task.core")
local due = require("todo2.handlers.due")
local actions = require("todo2.ai.actions")

local function due_of(id)
	local task = core.get_task(id)
	return task and task.core.due or nil
end

--- 每轮都重置成同一个到期日
local function seed(id, value)
	local ok = due.set_due_for_id(id, value)
	assert(ok, "seed failed")
	vim.wait(50, function()
		return false
	end)
end

-- 1. set_due_for_id("") 清空（MCP 与日历共用这条路径）
seed("aaa111", "2026-11-02")
check(due_of("aaa111") == "2026-11-02", "due is set before clearing")
check(due.set_due_for_id("aaa111", "") == true and due_of("aaa111") == nil, "empty value clears the due date")

-- 2. 显式关键字：none / clear / -
for _, word in ipairs({ "none", "clear", "-" }) do
	seed("aaa111", "2026-11-02")
	local ok = due.set_due_for_id("aaa111", word)
	check(ok == true and due_of("aaa111") == nil, (":TodoDue %s clears the due date"):format(word))
end

-- 3. MCP 路径：ai.actions.set_due(id, "")
seed("bbb222", "2026-12-24")
local res = actions.set_due("bbb222", "")
check(res ~= nil and res.due == nil and due_of("bbb222") == nil, "MCP set_due with an empty string clears the due date")

-- 4. 交互输入框留空 = 清除
seed("bbb222", "2026-12-24")
local orig_input = vim.ui.input
vim.ui.input = function(_, cb)
	cb("")
end
local ok_prompt = pcall(due.due_for_id, "bbb222", nil)
vim.ui.input = orig_input
check(ok_prompt and due_of("bbb222") == nil, "empty prompt input clears the due date")

-- 5. 输入框取消（nil）不清除
seed("bbb222", "2026-12-24")
vim.ui.input = function(_, cb)
	cb(nil)
end
pcall(due.due_for_id, "bbb222", nil)
vim.ui.input = orig_input
check(due_of("bbb222") == "2026-12-24", "cancelled prompt keeps the due date")

-- 6. 非法输入仍然报错且不改变现状
seed("bbb222", "2026-12-24")
local ok_bad = due.set_due_for_id("bbb222", "someday")
check(ok_bad == false and due_of("bbb222") == "2026-12-24", "invalid input is rejected and keeps the due date")

-- 7. 文件行同步：清空后 @date 从 TODO 行移除
seed("aaa111", "2026-11-02")
vim.cmd("silent! edit! " .. dir .. "/a.todo.md")
vim.cmd("TodoSync")
local line_before = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
due.set_due_for_id("aaa111", "")
vim.wait(300, function()
	return false
end)
local line_after = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
check(
	line_before:find("@2026%-11%-02") ~= nil and line_after:find("@2026") == nil,
	"clearing removes the @date from the TODO line"
)

print("")
if failures == 0 then
	print("ALL PASS (" .. checks .. " checks)")
else
	print(failures .. " FAILED of " .. checks)
	os.exit(1)
end
