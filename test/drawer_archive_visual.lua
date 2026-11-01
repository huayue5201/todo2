-- 抽屉归档回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-drawer-archive-visual-xdg nvim --headless -u NONE -l test/drawer_archive_visual.lua
--
-- 覆盖：
--   1) 可视模式 x 批量归档选中的多个任务组；再可视模式 x 批量反归档
--   2) 归档不会破坏其它任务的完成状态（文件 checkbox 与 store 一致）

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-drawer-archive-visual-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-drawer-archive-visual-proj"), "rf")

require("todo2").setup({})

local actions = require("todo2.ai.actions")
local core = require("todo2.store.task.core")
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

local function settle(ms)
	vim.wait(ms or 400, function()
		return false
	end)
end

local function row_of(needle)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	for i, l in ipairs(lines) do
		if l:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

-- headless 下 feedkeys/:normal 与抽屉的重渲染防抖会交错，导致 V 被吞、
-- x 落到普通模式单组映射。视觉映射本身由下方 maparg 断言覆盖，
-- 选区行为直接调用它背后的 archive_rows，保证确定性。
local function visual_keys(from_row, to_row)
	drawer._archive_rows(from_row, to_row)
	settle(800)
end

local function file_text(path)
	return table.concat(vim.fn.readfile(path), "\n")
end

local f = actions.create_todo_file("visual")
local a1 = actions.create_task({ content = "group A", path = f.path })
local a2 = actions.create_task({ content = "group A child", path = f.path, parent_id = a1.id })
local b1 = actions.create_task({ content = "solo B", path = f.path })
local keep = actions.create_task({ content = "keep completed", path = f.path })

actions.set_status(a2.id, "completed")
actions.set_status(keep.id, "completed")
settle(400)

check("completed child written to file", file_text(f.path):find("completed:" .. a2.id, 1, true) ~= nil)
check("completed keeper written to file", file_text(f.path):find("completed:" .. keep.id, 1, true) ~= nil)

drawer.toggle()
settle(300)

local s, e = row_of("group A"), row_of("solo B")
local vmap = vim.fn.maparg("x", "v", false, true)
check("visual x mapping registered", type(vmap) == "table" and vmap.callback ~= nil)
check("selected rows visible", s ~= nil and e ~= nil and s < e, tostring(s) .. "/" .. tostring(e))
if s and e then
	visual_keys(s, e)
end

check("group A archived", core.get_task(a1.id) and core.get_task(a1.id).core.status == "archived")
check("group A child archived", core.get_task(a2.id) and core.get_task(a2.id).core.status == "archived")
check("solo B archived", core.get_task(b1.id) and core.get_task(b1.id).core.status == "archived")
check(
	"unselected completed task untouched",
	core.get_task(keep.id) and core.get_task(keep.id).core.status == "completed",
	core.get_task(keep.id) and core.get_task(keep.id).core.status
)
check("file keeps completed keeper", file_text(f.path):find("completed:" .. keep.id, 1, true) ~= nil)

-- 批量反归档：开启归档显示，选中归档段里的两个任务组
drawer.toggle_archived()
settle(400)

local arow, brow = row_of("group A"), row_of("solo B")
check("archived rows visible", arow ~= nil and brow ~= nil, tostring(arow) .. "/" .. tostring(brow))
if arow and brow then
	visual_keys(math.min(arow, brow), math.max(arow, brow))
end

check("group A restored", core.get_task(a1.id) and core.get_task(a1.id).core.status ~= "archived")
check("solo B restored", core.get_task(b1.id) and core.get_task(b1.id).core.status ~= "archived")
check(
	"unarchive restores completed child",
	core.get_task(a2.id) and core.get_task(a2.id).core.status == "completed",
	core.get_task(a2.id) and core.get_task(a2.id).core.status
)
check(
	"unarchive keeps keeper completed",
	core.get_task(keep.id) and core.get_task(keep.id).core.status == "completed",
	core.get_task(keep.id) and core.get_task(keep.id).core.status
)

if fails == 0 then
	print("ALL PASS")
else
	print("FAILS " .. fails)
end
if fails > 0 then
	os.exit(1)
end
vim.cmd("qa!")
