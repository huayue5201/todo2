-- 抽屉批量删除（可视模式 <BS>）测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-drawer-del-xdg nvim --headless -u NONE -l test/drawer_delete.lua
--
-- 覆盖：普通模式 <BS> 仍删单条子树；可视模式选中父+子 → 一次删净、
--       不重复提交（不会报 failed）；选区外任务保留；归档任务拒绝删除。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-drawer-del-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-drawer-del-proj"), "rf")

require("todo2").setup({})

local actions = require("todo2.ai.actions")
local drawer = require("todo2.ui.drawer")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local f = actions.create_todo_file("del")
local a = actions.create_task({ content = "A parent", path = f.path })
local a1 = actions.create_task({ content = "A child 1", path = f.path, parent_id = a.id })
local a2 = actions.create_task({ content = "A child 2", path = f.path, parent_id = a.id })
local b = actions.create_task({ content = "B keep", path = f.path })
local c = actions.create_task({ content = "C single", path = f.path })
local c1 = actions.create_task({ content = "C child", path = f.path, parent_id = c.id })

local function drawer_buf()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "todo2drawer" then
			return buf
		end
	end
	return nil
end

local function line_of(needle)
	for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
		if l:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

drawer.toggle()
vim.wait(300, function()
	return false
end)
check("drawer open", drawer_buf() ~= nil)
-- 默认折叠，先全展开，才能选到子任务行
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("zR", true, false, true), "x", false)
vim.wait(300)

-- 1) 可视模式选中父 + 两个子 → 一次删净，且不产生「failed」计数
local first = line_of("A parent")
local last = line_of("A child 2")
check("drawer rows found", first ~= nil and last ~= nil and last > first, tostring(first) .. "/" .. tostring(last))
vim.api.nvim_win_set_cursor(0, { first, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("V" .. (last - first) .. "j<BS>", true, false, true), "x", false)
vim.wait(500)

check("batch: parent gone", core.get_task(a.id) == nil)
check("batch: child 1 gone", core.get_task(a1.id) == nil)
check("batch: child 2 gone", core.get_task(a2.id) == nil)
check("batch: no dangling children", relation.get_child_ids(a.id) == nil or #relation.get_child_ids(a.id) == 0)
check("batch: outside task kept", core.get_task(b.id) ~= nil and core.get_task(c.id) ~= nil)
check("batch: drawer still open", drawer_buf() ~= nil)

-- 2) 普通模式 <BS> 仍是「单条 + 整棵子树」
local cline = line_of("C single")
check("single row found", cline ~= nil)
vim.api.nvim_win_set_cursor(0, { cline, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "x", false)
vim.wait(500)
check("single: parent gone", core.get_task(c.id) == nil)
check("single: subtree gone", core.get_task(c1.id) == nil)

-- 3) 归档段里的任务不能被批量删除（提示先 unarchive）
local e = actions.create_task({ content = "E archived", path = f.path })
local ok_arch = actions.archive_task(e.id)
check("archive ok", ok_arch ~= nil, tostring(ok_arch))
drawer.toggle() -- 关
drawer.toggle() -- 重开，重新渲染
vim.wait(200)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "x", false) -- 显示归档
vim.wait(300)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("zR", true, false, true), "x", false)
vim.wait(300)
local eline = line_of("E archived")
check("archived row visible", eline ~= nil)
if eline then
	vim.api.nvim_win_set_cursor(0, { eline, 0 })
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("V<BS>", true, false, true), "x", false)
	vim.wait(400)
	check("archived task untouched", core.get_task(e.id) ~= nil)
end

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
