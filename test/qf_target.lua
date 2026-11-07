-- quickfix 落点窗口回归测试：
-- 抽屉里打开 quickfix（Q / gr）后跳转，不得把目标文件塞进抽屉窗口。
-- 运行：XDG_DATA_HOME=/tmp/todo2-qf-target-xdg nvim --headless -u NONE -l test/qf_target.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local proj = "/tmp/todo2-qf-target-proj"
vim.fn.delete(proj, "rf")
vim.fn.mkdir(proj .. "/src", "p")
vim.fn.chdir(proj)
vim.fn.system({ "git", "-C", proj, "init", "-q" })

require("todo2").setup({})
vim.fn.delete(require("todo2.utils.project").current().dir, "rf")

local actions = require("todo2.ai.actions")
local drawer = require("todo2.ui.drawer")
local git_handler = require("todo2.handlers.git")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local todo = actions.create_todo_file("qf_target")
local alpha = actions.create_task({ content = "alpha task", path = todo.path })
actions.create_task({ content = "beta task", path = todo.path })

-- 代码文件 + 代码锚点（git review 用）
local code = proj .. "/src/main.lua"
vim.fn.writefile({ "local function foo()", "  return 1", "end" }, code)
local linked, link_err = actions.link_code(alpha.id, code, 2)
check("code anchor created", linked ~= nil, link_err)
vim.cmd("silent wa")

-- 弄脏代码文件（git review 只列脏文件里的锚点）
vim.fn.writefile({ "local function foo()", "  return 2", "end" }, code)

-- 一个普通编辑窗口作为「main」，抽屉从它打开
local main = proj .. "/src/other.lua"
vim.fn.writefile({ "return {}" }, main)
vim.cmd.edit(vim.fn.fnameescape(main))
local main_win = vim.api.nvim_get_current_win()

drawer.toggle()
vim.wait(400, function()
	return drawer.is_open()
end)
local drawer_win = vim.api.nvim_get_current_win()
local drawer_buf = vim.api.nvim_get_current_buf()
check("drawer opened", drawer.is_drawer(drawer_buf))
check("drawer window is pinned (winfixbuf)", vim.wo[drawer_win].winfixbuf == true)

local function drawer_intact(tag)
	check(tag .. ": drawer window still shows drawer", vim.api.nvim_win_get_buf(drawer_win) == drawer_buf)
	check(tag .. ": drawer still open", drawer.is_open())
end

---------------------------------------------------------------------
-- Q（抽屉导出 quickfix）
---------------------------------------------------------------------
drawer.quickfix()
vim.wait(200, function()
	return #vim.fn.getqflist() > 0
end)
check("drawer qf non-empty", #vim.fn.getqflist() > 0, #vim.fn.getqflist())
check("qf opened from a non-drawer window", vim.api.nvim_get_current_win() ~= drawer_win)
drawer_intact("after copen")

vim.cmd("cc 1")
vim.wait(100, function()
	return false
end)
drawer_intact("after qf jump")
check("qf jump landed in the main window", vim.api.nvim_get_current_win() == main_win,
	vim.api.nvim_get_current_win())

-- 残留场景：用户先回到抽屉，再从抽屉里触发 qf 跳转
vim.api.nvim_set_current_win(drawer_win)
vim.cmd("cc 2")
vim.wait(100, function()
	return false
end)
drawer_intact("after jump from drawer focus")
check("drawer buffer still valid", vim.api.nvim_buf_is_valid(drawer_buf))
pcall(vim.cmd, "cclose")
vim.fn.setqflist({}, "r")

---------------------------------------------------------------------
-- gr（git review，用户报的复现路径）
---------------------------------------------------------------------
vim.api.nvim_set_current_win(drawer_win)
git_handler.review()
vim.wait(200, function()
	return #vim.fn.getqflist() > 0
end)
check("git review qf non-empty", #vim.fn.getqflist() > 0, #vim.fn.getqflist())
drawer_intact("after gr copen")
check("gr qf opened from a non-drawer window", vim.api.nvim_get_current_win() ~= drawer_win)

vim.cmd("cc 1")
vim.wait(100, function()
	return false
end)
drawer_intact("after gr jump")
check("gr jump opened the code file", vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(code),
	vim.api.nvim_buf_get_name(0))

---------------------------------------------------------------------
-- 其它会打开真实 buffer 的路径（:TodoOpen edit / split）
---------------------------------------------------------------------
local win_ui = require("todo2.ui.window")
vim.api.nvim_set_current_win(drawer_win)
win_ui.open_todo_file(todo.path, "edit", 1, { enter_insert = false })
drawer_intact("after open_todo_file edit from drawer")
check("edit opened the TODO file", vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(todo.path),
	vim.api.nvim_buf_get_name(0))

vim.api.nvim_set_current_win(drawer_win)
win_ui.open_todo_file(todo.path, "split", 1, { enter_insert = false })
drawer_intact("after open_todo_file split from drawer")
check("split opened the TODO file", vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(todo.path),
	vim.api.nvim_buf_get_name(0))

print(fails == 0 and "ALL OK" or ("FAILURES: " .. fails))
vim.cmd(fails == 0 and "qall!" or "cquit")
