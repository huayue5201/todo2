-- 抽屉折叠（za / zc）回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-drawer-fold-xdg nvim --headless -u NONE -l test/drawer_fold.lua
--
-- 覆盖：任务节点展开/收起；文件头的展开/收起；
--       筛选开启时（needed_expand 强制展开命中路径）za/zc 仍然生效。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-drawer-fold-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(require("todo2.utils.project").current().dir, "rf")

require("todo2").setup({})

local actions = require("todo2.ai.actions")
local filter = require("todo2.render.filter")
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

local file = actions.create_todo_file("fold")
local parent = actions.create_task({ content = "parent task", path = file.path, tags = { "fix" } })
check("parent created", parent ~= nil, parent and parent.id)
actions.create_task({ content = "child one", path = file.path, parent_id = parent.id, tags = { "fix" } })

drawer.toggle()
vim.wait(300, function()
	return drawer.is_open()
end)

local buf = vim.api.nvim_get_current_buf()
check("drawer open", drawer.is_drawer(buf))

local function lines()
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function has(needle)
	for _, l in ipairs(lines()) do
		if l:find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function row_of(needle)
	for i, l in ipairs(lines()) do
		if l:find(needle, 1, true) then
			return i
		end
	end
end

local function press(keys)
	vim.api.nvim_win_set_cursor(0, { row_of(keys.needle) or 1, 0 })
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys.keys, true, false, true), "x", false)
	vim.wait(300, function()
		return false
	end)
end

local function fold_on(needle, keys)
	press({ needle = needle, keys = keys })
end

---------------------------------------------------------------------
-- 无筛选：任务节点
---------------------------------------------------------------------
check("child hidden by default", not has("child one"), table.concat(lines(), "\n"))
fold_on("parent task", "za")
check("za expands the task", has("child one"), table.concat(lines(), "\n"))
fold_on("parent task", "za")
check("za collapses the task", not has("child one"), table.concat(lines(), "\n"))
fold_on("parent task", "zo")
check("zo expands the task", has("child one"))
fold_on("parent task", "zc")
check("zc collapses the task", not has("child one"))

---------------------------------------------------------------------
-- 无筛选：文件头
---------------------------------------------------------------------
fold_on("fold.todo.md", "za")
check("za collapses the file group", not has("parent task"), table.concat(lines(), "\n"))
fold_on("fold.todo.md", "za")
check("za expands the file group", has("parent task"))

---------------------------------------------------------------------
-- 筛选开启：needed_expand 强制展开命中路径，za 仍须生效
---------------------------------------------------------------------
drawer.set_filter(filter.parse({ "#fix" }))
check("filter keeps parent", has("parent task"))
check("filter auto-expands the path", has("child one"))

fold_on("parent task", "za")
check("za collapses a filtered task", not has("child one"), table.concat(lines(), "\n"))
fold_on("parent task", "za")
check("za re-expands a filtered task", has("child one"))

fold_on("parent task", "zc")
check("zc collapses a filtered task", not has("child one"))
fold_on("parent task", "zo")
check("zo expands a filtered task", has("child one"))

fold_on("fold.todo.md", "za")
check("za collapses a filtered file group", not has("parent task"), table.concat(lines(), "\n"))
fold_on("fold.todo.md", "za")
check("za expands a filtered file group", has("parent task"))

drawer.clear_filter()

if fails == 0 then
	print("ALL PASS")
else
	print("FAILS " .. fails)
end
vim.cmd("qa!")
