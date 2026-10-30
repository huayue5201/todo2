-- 日历跳转测试：有代码锚点就跳代码，没有才退回 TODO 行（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/calendar_jump.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local proj = "/tmp/todo2-cal-jump-proj"
vim.fn.delete(proj, "rf")
vim.fn.mkdir(proj .. "/src", "p")
vim.fn.chdir(proj)
local dir = vim.fn.expand("~/.todo-files/todo2-cal-jump-proj")
vim.fn.delete(dir, "rf")
vim.fn.mkdir(dir, "p")

local code_path = proj .. "/src/main.go"
vim.fn.writefile({
	"package main",
	"",
	"func main() {",
	"\tprintln(\"hi\")", -- 目标行（第 4 行）
	"}",
}, code_path)

local today = require("todo2.utils.due").today()
local todo_path = dir .. "/main.todo.md"
vim.fn.writefile({
	"## Active",
	"- [ ] todo:cj0001 @" .. today .. " A 有代码锚点的任务",
	"- [ ] todo:cj0002 @" .. today .. " B 只有 TODO 行的任务",
}, todo_path)

require("todo2").setup({})
vim.cmd("edit " .. vim.fn.fnameescape(todo_path))

local core = require("todo2.store.task.core")
local jumper = require("todo2.task.jumper")
local view = require("todo2.ui.calendar.view")

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
	local ok, a = pcall(core.get_task, "cj0001")
	local ok2, b = pcall(core.get_task, "cj0002")
	return ok and a ~= nil and ok2 and b ~= nil
end, 50)

-- 给 cj0001 挂一个已核验的代码锚点（第 4 行，col 0）
local task = core.get_task("cj0001")
check("task indexed", task ~= nil)
if task then
	task.locations.code = {
		path = code_path,
		line = 4,
		col = 0,
		end_col = 7,
		snippet = "println",
		context = { type = "block", source = "indent" },
		-- verification 会拿 line_text（去空白指纹）比对真实代码行，写错就会被判 lost
		line_text = 'println("hi")',
	}
	core.set_anchor_state(task, core.ANCHOR.OK)
	core.save_task("cj0001", task)
end

local function realpath(p)
	return vim.uv.fs_realpath(p) or p
end

local function current_path()
	return realpath(vim.api.nvim_buf_get_name(0))
end

-- 1) 直接调用 jumper
vim.cmd("edit " .. vim.fn.fnameescape(todo_path))
check("jump_to_task handled", jumper.jump_to_task("cj0001") == true)
vim.wait(500, function()
	return current_path() == realpath(code_path) and vim.fn.line(".") == 4
end, 20)
check("jumps to the code file", current_path() == realpath(code_path), current_path())
check("jumps to the anchor line", vim.fn.line(".") == 4, vim.fn.line("."))

-- 2) 没有锚点的任务退回 TODO 行
vim.cmd("edit " .. vim.fn.fnameescape(todo_path))
check("jump_to_task handled (no anchor)", jumper.jump_to_task("cj0002") == true)
vim.wait(500, function()
	return current_path() == realpath(todo_path)
end, 20)
local todo_abs = realpath(todo_path)
check("falls back to the TODO file", current_path() == todo_abs, current_path())
check("falls back to the TODO line", vim.fn.line(".") == 3, vim.fn.line("."))

-- 3) 日历日视图里 <CR> 也走代码锚点
local function feed(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
local buf = view.open({ year = tonumber(today:sub(1, 4)), month = tonumber(today:sub(6, 7)), day = tonumber(today:sub(9, 10)) })
vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
feed("<CR>") -- 进入当日列表
feed("<CR>") -- 跳到第一条任务
vim.wait(800, function()
	return current_path() == realpath(code_path) and vim.fn.line(".") == 4
end, 20)
check("calendar <CR> lands on code, not the md list", current_path() == realpath(code_path), current_path())
check("calendar <CR> lands on the anchor line", vim.fn.line(".") == 4, vim.fn.line("."))

vim.fn.delete(dir, "rf")
vim.fn.delete(proj, "rf")
print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
