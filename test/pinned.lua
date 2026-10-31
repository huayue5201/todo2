-- 搁置（pinned）：存储字段、抽屉呈现、以及 checkbox 驱动的终态迁移。
-- 运行：XDG_DATA_HOME=/tmp/todo2-pinned-xdg nvim --headless -u NONE -l test/pinned.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-pinned-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-pinned-proj"), "rf")

require("todo2").setup({})
vim.cmd("runtime! plugin/todo2.lua")

local actions = require("todo2.ai.actions")
local core = require("todo2.store.task.core")
local schema = require("todo2.store.schema")
local sync = require("todo2.core.sync")
local status_domain = require("todo2.core.status")
local pin = require("todo2.handlers.pin")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local f = actions.create_todo_file("pinned")
local rpath = vim.fn.fnamemodify(f.path, ":p")

---------------------------------------------------------------------
-- 1) 存储字段
---------------------------------------------------------------------
local a = actions.create_task({ content = "搁置我", path = rpath })
check("create task", a and a.id)
check("not pinned by default", (core.get_task(a.id).core.pinned) == nil)

check("pin_for_id returns true", pin.pin_for_id(a.id) == true)
check("pinned is true", core.get_task(a.id).core.pinned == true)

-- 契约：重新读一遍（走 schema.normalize_task）仍保留
local raw = schema.normalize_task(core.get_task(a.id), a.id)
check("schema keeps pinned", raw.core.pinned == true)
check("schema drops non-boolean pinned", (schema.normalize_task({ core = { content = "x", pinned = "yes" } }, "z").core.pinned) == nil)

-- 清空
check("unpin returns true", pin.pin_for_id(a.id) == true)
check("pinned cleared", (core.get_task(a.id).core.pinned) == nil)

-- 再置位，留给抽屉断言
pin.pin_for_id(a.id)
local b = actions.create_task({ content = "没搁置", path = rpath })
sync.sync_todo_file(rpath)

---------------------------------------------------------------------
-- 2) 抽屉：⚑ 徽章 + 排在同级最后
---------------------------------------------------------------------
local drawer = require("todo2.ui.drawer")
drawer.toggle()
vim.wait(100)
local dbuf
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
	if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "todo2drawer" then
		dbuf = buf
	end
end
check("drawer open", dbuf ~= nil)
local dlines = vim.api.nvim_buf_get_lines(dbuf, 0, -1, false)
local idx_pinned, idx_plain
for i, l in ipairs(dlines) do
	if l:find("搁置我") then
		idx_pinned = i
	end
	if l:find("没搁置") then
		idx_plain = i
	end
end
check("pinned row rendered", idx_pinned ~= nil)
check("plain row rendered", idx_plain ~= nil)
check("pinned row last", idx_pinned ~= nil and idx_plain ~= nil and idx_pinned > idx_plain, tostring(idx_pinned) .. "/" .. tostring(idx_plain))
check("pinned row has badge", (function()
	for _, l in ipairs(dlines) do
		if l:find("搁置我") then
			return l:find("⚑", 1, true) ~= nil
		end
	end
	return false
end)())
drawer.toggle() -- 已开 -> toggle 关闭
vim.wait(50)

---------------------------------------------------------------------
-- 3) checkbox 驱动的终态迁移（文件是真源）
---------------------------------------------------------------------
-- sync 优先读「已加载的缓冲区」，所以这里直接改 buffer（和用户手改 checkbox 一致）
vim.cmd("edit! " .. vim.fn.fnameescape(rpath))
local tbuf = vim.api.nvim_get_current_buf()

local function set_checkbox(id, checked)
	local blines = vim.api.nvim_buf_get_lines(tbuf, 0, -1, false)
	for i, l in ipairs(blines) do
		if l:find(id, 1, true) then
			blines[i] = l:gsub("%- %[[ x]%]", "- [" .. checked .. "]", 1)
		end
	end
	vim.api.nvim_buf_set_lines(tbuf, 0, -1, false, blines)
end

set_checkbox(a.id, "x")
sync.sync_todo_file(rpath)

local t = core.get_task(a.id)
check("checkbox [x] -> completed", t and t.core.status == "completed", t and t.core.status)
check(
	"completed timestamp set",
	t and type(t.timestamps.completed) == "number" and t.timestamps.completed > 0,
	t and tostring(t.timestamps.completed)
)

-- 退回未完成：completed 时间戳要一起清掉
set_checkbox(a.id, " ")
sync.sync_todo_file(rpath)

t = core.get_task(a.id)
check(
	"checkbox [ ] -> back to active",
	t and not require("todo2.store.types").is_completed_status(t.core.status),
	t and t.core.status
)
check("completed timestamp cleared", t and t.timestamps.completed == nil, t and tostring(t.timestamps.completed))

---------------------------------------------------------------------
-- 4) 活跃状态不被 [ ] 覆盖（doing 在文件里也写成 [ ]）
---------------------------------------------------------------------
status_domain.set_status(b.id, "doing", "test")
sync.sync_todo_file(rpath)
check("active status preserved", core.get_task(b.id).core.status == "doing", core.get_task(b.id).core.status)

---------------------------------------------------------------------
-- 5) 属性面板有 Pinned 行
---------------------------------------------------------------------
local attrs = require("todo2.ui.attributes")
require("todo2.ui.attributes").open(b.id)
vim.wait(50)
local abuf
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
	if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "todo2attrs" then
		abuf = buf
	end
end
check("attributes open", abuf ~= nil)
local alines = vim.api.nvim_buf_get_lines(abuf, 0, -1, false)
local has_row = false
for _, l in ipairs(alines) do
	if l:find("Pinned", 1, true) then
		has_row = true
	end
end
check("attributes has Pinned row", has_row)
attrs.close()

print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
if fails > 0 then
	vim.cmd("cquit 1")
end
vim.cmd("qa!")
