-- quickfix 快照：TODO 文件 / 抽屉 / 日历（尊重各自筛选）（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-qf-xdg nvim --headless -u NONE -l test/quickfix.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-qf-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)

require("todo2").setup({})
vim.fn.delete(require("todo2.utils.project").current().dir, "rf")

local actions = require("todo2.ai.actions")
local drawer = require("todo2.ui.drawer")
local filter = require("todo2.render.filter")
local filter_cmd = require("todo2.handlers.filter").filter_cmd
local qf = require("todo2.task.quickfix")
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

local f = actions.create_todo_file("quickfix")
local alpha = actions.create_task({ content = "alpha task", path = f.path, tags = { "fix" } })
local beta = actions.create_task({ content = "beta task", path = f.path, tags = { "backend" } })
actions.create_task({ content = "gamma task", path = f.path })
actions.set_status(beta.id, "doing")

vim.cmd.edit(vim.fn.fnameescape(f.path))
vim.wait(300, function()
	return false
end)

local function qf_texts()
	local out = {}
	for _, item in ipairs(vim.fn.getqflist()) do
		out[#out + 1] = item.text
	end
	return table.concat(out, "\n")
end

local function close_qf()
	pcall(vim.cmd, "cclose")
end

local function feed(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---把当前 qf 快照关掉、清空，避免不同来源互相干扰
local function reset_qf()
	close_qf()
	vim.fn.setqflist({}, "r")
end

---------------------------------------------------------------------
-- TODO 文件 + 缓冲区筛选
---------------------------------------------------------------------
filter_cmd({ fargs = { "#fix" } })
local items, title = qf.buffer_items(vim.api.nvim_get_current_buf())
check("buffer items returned", items ~= nil)
check("buffer filter keeps hit only", #items == 1 and items[1].text:find("alpha task", 1, true) ~= nil,
	vim.inspect(items))
check("buffer item points at the TODO file", items[1].filename == f.path, items[1].filename)
check("buffer title carries filter", title and title:find("#fix", 1, true) ~= nil, title)
check("buffer item has user_data id", items[1].user_data and items[1].user_data.id ~= nil)

filter_cmd({ fargs = {}, bang = true })
items = qf.buffer_items(vim.api.nvim_get_current_buf())
check("cleared filter exports all tasks", #items == 3, #items)
check("non-todo path rejected", (function()
	local tmp = vim.fn.tempname() .. ".lua"
	vim.fn.writefile({ "return 1" }, tmp)
	vim.cmd.edit(vim.fn.fnameescape(tmp))
	local got = qf.buffer_items(vim.api.nvim_get_current_buf())
	vim.cmd.edit(vim.fn.fnameescape(f.path))
	return got == nil
end)())

---------------------------------------------------------------------
-- 抽屉 + 抽屉筛选
---------------------------------------------------------------------
drawer.toggle()
vim.wait(400, function()
	return drawer.is_open()
end)
local dbuf = vim.api.nvim_get_current_buf()
check("drawer open", drawer.is_drawer(dbuf))
drawer.set_filter(filter.parse({ "fix" }))
feed("Q")
vim.wait(200, function()
	return #vim.fn.getqflist() > 0
end)
local qitems = vim.fn.getqflist()
check("drawer qf opened with one hit", #qitems == 1, #qitems)
check("drawer qf text is alpha", qitems[1].text:find("alpha task", 1, true) ~= nil, qitems[1].text)
check("drawer qf jumped to file", vim.fn.bufname(qitems[1].bufnr) == f.path, vim.fn.bufname(qitems[1].bufnr))
reset_qf()
drawer.clear_filter()
drawer.quickfix()
check("unfiltered drawer exports all", #vim.fn.getqflist() == 3, #vim.fn.getqflist())
reset_qf()
drawer.toggle()

---------------------------------------------------------------------
-- TODO 文件：scope:self / scope:tree（与抽屉同语义）
---------------------------------------------------------------------
vim.cmd.edit(vim.fn.fnameescape(f.path))
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
lines[#lines + 1] = "- [ ] parent matched @id(qfparent) #fix"
lines[#lines + 1] = "  - [ ] child one @id(qfchild1)"
lines[#lines + 1] = "  - [ ] child two @id(qfchild2)"
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
require("todo2.core.sync").sync_todo_file(f.path)

filter_cmd({ fargs = { "#fix" } })
items = qf.buffer_items(vim.api.nvim_get_current_buf())
local joined = table.concat(vim.tbl_map(function(it)
	return it.text
end, items), "\n")
check("scope:self keeps the hit parent", joined:find("parent matched", 1, true) ~= nil, joined)
check("scope:self hides its children", joined:find("child one", 1, true) == nil, joined)
filter_cmd({ fargs = { "#fix", "scope:tree" } })
items = qf.buffer_items(vim.api.nvim_get_current_buf())
joined = table.concat(vim.tbl_map(function(it)
	return it.text
end, items), "\n")
check("scope:tree keeps children", joined:find("child one", 1, true) ~= nil, joined)
filter_cmd({ fargs = {}, bang = true })

---------------------------------------------------------------------
-- 日历（月视图，事务已按 due 过滤）
---------------------------------------------------------------------
local due = require("todo2.utils.due").today()
actions.set_due(beta.id, due)
actions.set_due(alpha.id, due)
local y, m = tonumber(due:sub(1, 4)), tonumber(due:sub(6, 7))
view.open({ year = y, month = m })
check("calendar open", view.is_open())
-- 月历 service 同步/异步都可能；wait 一小段让首帧条目落地
vim.wait(600, function()
	return false
end)
view.set_filter(filter.append(filter.parse({ "#fix" }), filter.parse({ "status:active" })))
vim.wait(500, function()
	return false
end)
feed("Q")
vim.wait(300, function()
	return #vim.fn.getqflist() > 0
end)
local citems = vim.fn.getqflist()
check("calendar qf non-empty", #citems > 0, #citems)
check("calendar filter keeps alpha", qf_texts():find("alpha task", 1, true) ~= nil, qf_texts())
check("calendar filter drops beta", qf_texts():find("beta task", 1, true) == nil, qf_texts())
check("calendar qf points at a file", citems[1].filename ~= "", citems[1].filename)
reset_qf()
view.set_filter(nil)
view.close()

---------------------------------------------------------------------
-- 命令分发
---------------------------------------------------------------------
local commands = require("todo2.commands")
vim.cmd.edit(vim.fn.fnameescape(f.path))
filter_cmd({ fargs = { "#backend" } })
commands.quickfix()
check(":TodoQuickfix from TODO buffer respects filter", #vim.fn.getqflist() == 1, #vim.fn.getqflist())
check("command opened a window list", vim.fn.getqflist({ title = 1 }).title:find("#backend", 1, true) ~= nil,
	vim.fn.getqflist({ title = 1 }).title)
reset_qf()

print(fails == 0 and "ALL OK" or ("FAILURES: " .. fails))
vim.cmd(fails == 0 and "qall!" or "cquit")
