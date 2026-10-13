-- 抽屉归档键位（x）回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-drawer-archive-xdg nvim --headless -u NONE -l test/drawer_archive.lua
--
-- 覆盖：光标在活跃任务上按 x -> 归档该任务组；开启归档显示后光标在归档节点上按 x -> 反归档。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-drawer-archive-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-drawer-archive-proj"), "rf")

require("todo2").setup({})

local actions = require("todo2.ai.actions")
local core = require("todo2.store.task.core")
local store_archive = require("todo2.store.archive")
local drawer = require("todo2.ui.drawer")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local function line_of(needle)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	for i, l in ipairs(lines) do
		if l:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

local f = actions.create_todo_file("drawer")
local r = actions.create_task({ content = "drawer alpha", path = f.path })
check("create task", r and r.id ~= nil, r and r.id)
local id = r.id

drawer.toggle()
vim.wait(200, function()
	return false
end)

local l = line_of("drawer alpha")
check("task visible in drawer", l ~= nil, l)
if l then
	vim.api.nvim_win_set_cursor(0, { l, 0 })
	vim.api.nvim_feedkeys("x", "x", false)
	vim.wait(400, function()
		return false
	end)
end

check("task archived (gone from main store)", core.get_task(id) == nil)
check("archive store has group", store_archive.count() > 0, store_archive.count())

-- 开启归档显示，光标落到归档节点上，按 x 反归档
drawer.toggle_archived()
vim.wait(300, function()
	return false
end)

local al = nil
do
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	for i, ln in ipairs(lines) do
		if ln:find("drawer alpha", 1, true) and i >= (l or 1) then
			al = i
		end
	end
end
check("archived task visible after A", al ~= nil, al)
if al then
	vim.api.nvim_win_set_cursor(0, { al, 0 })
	vim.api.nvim_feedkeys("x", "x", false)
	vim.wait(400, function()
		return false
	end)
end

check("task restored (back in main store)", core.get_task(id) ~= nil)

if fails == 0 then
	print("ALL PASS")
else
	print("FAILS " .. fails)
end
vim.cmd("qa!")
