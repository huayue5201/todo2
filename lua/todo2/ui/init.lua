-- lua/todo2/ui/init.lua
local M = {}

-- 延迟加载子模块
local modules = {
	constants = nil,
	conceal = nil,
	operations = nil,
	file_manager = nil,
	statistics = nil,
	keymaps = nil,
	window = nil,
}

local function get_module(name)
	if not modules[name] then
		modules[name] = require("todo2.ui." .. name)
	end
	return modules[name]
end

-- 外部渲染模块
local render = require("todo2.render")

---------------------------------------------------------------------
-- ⭐ 专业版刷新逻辑：UI 只负责渲染，不负责解析 / 统计 / 联动
---------------------------------------------------------------------
function M.refresh(bufnr)
	-- UI 层只负责渲染，不负责解析任务树
	local render = require("todo2.render")

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 渲染 UI（render_all 不再需要 roots）
	if render and render.render_all then
		render.render_all(bufnr)
	end
end

---------------------------------------------------------------------
-- 初始化窗口切换器
---------------------------------------------------------------------
local window_switcher = nil

local function init_window_switcher()
	if not window_switcher then
		local keymaps = get_module("keymaps")
		window_switcher = keymaps.create_window_switcher(M)

		M.switch_to_float = window_switcher.switch_to_float
		M.switch_to_split = window_switcher.switch_to_split
	end
	return window_switcher
end

---------------------------------------------------------------------
-- 打开 TODO 文件（保持原逻辑）
---------------------------------------------------------------------
function M.open_todo_file(path, mode, line_number, opts)
	opts = opts or {}
	local enter_insert = opts.enter_insert ~= false
	local split_direction = opts.split_direction or "horizontal"

	path = vim.fn.fnamemodify(path, ":p")

	if vim.fn.filereadable(path) == 0 then
		vim.notify("TODO文件不存在: " .. path, vim.log.levels.ERROR)
		return
	end

	line_number = line_number or 1

	local window = get_module("window")
	if mode == "float" then
		return window.show_floating(path, line_number, enter_insert, M)
	elseif mode == "split" then
		return window.show_split(path, line_number, enter_insert, split_direction, M)
	elseif mode == "edit" then
		return window.show_edit(path, line_number, enter_insert, M)
	else
		return window.show_edit(path, line_number, enter_insert, M)
	end
end

---------------------------------------------------------------------
-- 公开 API（保持原样）
---------------------------------------------------------------------
function M.select_todo_file(scope, callback)
	return get_module("file_manager").select_todo_file(scope, callback)
end

function M.create_todo_file()
	return get_module("file_manager").create_todo_file()
end

function M.delete_todo_file(path)
	return get_module("file_manager").delete_todo_file(path)
end

function M.toggle_selected_tasks()
	local bufnr = vim.api.nvim_get_current_buf()
	local win = vim.fn.bufwinid(bufnr)

	if win == -1 then
		vim.notify("未在窗口中找到缓冲区", vim.log.levels.ERROR)
		return 0
	end

	local operations = get_module("operations")
	local changed = operations.toggle_selected_tasks(bufnr, win)
	M.refresh(bufnr)
	return changed
end

function M.insert_task(text, indent_extra, bufnr)
	local operations = get_module("operations")
	return operations.insert_task(text, indent_extra, bufnr, M)
end

function M.clear_cache()
	return get_module("file_manager").clear_cache()
end

function M.apply_conceal(bufnr)
	return get_module("conceal").apply_conceal(bufnr)
end

function M.get_window_module()
	return get_module("window")
end

function M.get_keymaps_module()
	return get_module("keymaps")
end

function M.reload_modules()
	for name, _ in pairs(modules) do
		package.loaded["todo2.ui." .. name] = nil
		modules[name] = nil
	end
	package.loaded["todo2.ui"] = nil
	window_switcher = nil
	return require("todo2.ui")
end

return M
