-- 预览功能边界回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-preview-xdg nvim --headless -u NONE -l test/preview.lua
--
-- 覆盖：正常预览、陈旧锚点（行号超出文件长度）、锚点缺 line、空文件、
-- 错误路径不泄漏浮窗、补充任务继承祖先代码锚点。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-preview-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir .. "/src", "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-preview-proj"), "rf")

local code = projdir .. "/src/lib.rs"
vim.fn.writefile({ "pub fn alpha() {", "    1", "}", "pub fn beta() {", "    2", "}" }, code)

require("todo2").setup({ preview = { max_blocks = 20 } })

local actions = require("todo2.ai.actions")
local preview = require("todo2.task.preview")
local core = require("todo2.store.task.core")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local function float_count()
	local n = 0
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(w).relative ~= "" then
			n = n + 1
		end
	end
	return n
end

local function close_floats()
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(w).relative ~= "" then
			pcall(vim.api.nvim_win_close, w, true)
		end
	end
end

local f = actions.create_todo_file("pv")
local r = actions.create_task({ content = "anchored", path = f.path, anchor = { path = code, line = 1 } })
check("create task", r and r.id ~= nil, r and r.id)

local cb = vim.fn.bufadd(code)
vim.fn.bufload(cb)
vim.api.nvim_set_current_buf(cb)
vim.wait(300, function()
	return false
end)

-- 正常预览
close_floats()
local before = float_count()
check(
	"normal preview does not error",
	pcall(function()
		preview.preview_code_task(core.get_task(r.id))
	end)
)
check("normal preview opens a float", float_count() > before, float_count() .. " vs " .. before)

-- 陈旧锚点：行号超出文件长度 -> 夹紧，不报错
close_floats()
check(
	"stale line clamps without error",
	pcall(function()
		preview.preview_code_task({ id = r.id, locations = { code = { path = code, line = 9999 } } })
	end)
)
check("stale line still opens a float", float_count() > 0, float_count())

-- 锚点缺 line -> 只提示，不报错
close_floats()
check(
	"nil line does not error",
	pcall(function()
		preview.preview_code_task({ locations = { code = { path = code } } })
	end)
)

-- 空文件 -> 只提示，不报错
local empty = projdir .. "/src/empty.rs"
vim.fn.writefile({}, empty)
check(
	"empty code file does not error",
	pcall(function()
		preview.preview_code_task({ locations = { code = { path = empty, line = 1 } } })
	end)
)

-- 错误路径不泄漏浮窗
close_floats()
check("no leaked float after error paths", float_count() == 0, float_count())

-- 补充任务：自身无锚点，预览应回退到祖先锚点
local parent = actions.create_task({ content = "parent", path = f.path, anchor = { path = code, line = 4 } })
local child = actions.create_task({ content = "child", path = f.path, parent_id = parent.id })
vim.wait(300, function()
	return false
end)
close_floats()
check("inherited-anchor preview opens", pcall(function()
	preview.preview_code_task(core.get_task(child.id))
end) and float_count() > 0, float_count())
close_floats()

-- 跨 TODO 文件的同锚点任务：preview_todo 应平铺展示全部（受 preview.max_blocks 安全上限）
local f2 = actions.create_todo_file("pv2")
actions.create_task({ content = "anchored2", path = f.path, anchor = { path = code, line = 1 } })
actions.create_task({ content = "other", path = f2.path, anchor = { path = code, line = 1 } })
vim.wait(400, function()
	return false
end)
vim.api.nvim_set_current_buf(cb)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.wait(300, function()
	return false
end)
close_floats()
preview.preview_todo()
check("same-anchor tasks across TODO files all shown", float_count() == 3, float_count())
close_floats()

if fails == 0 then
	print("ALL PASS")
else
	print("FAILS " .. fails)
end
vim.cmd("qa!")
