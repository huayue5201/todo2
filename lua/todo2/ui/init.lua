-- lua/todo2/ui/init.lua
--- @module todo2.ui

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 延迟加载子模块
---------------------------------------------------------------------
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
		-- 使用模块管理器获取子模块
		modules[name] = module.get("ui." .. name)
	end
	return modules[name]
end

---------------------------------------------------------------------
-- ⭐ 增强版刷新逻辑：支持强制重新解析
---------------------------------------------------------------------
function M.refresh(bufnr, force_parse)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 使用模块管理器获取 render 模块
	local render_module = module.get("ui.render")

	-- 渲染 UI，传递 force_parse 参数
	if render_module and render_module.render_all then
		local rendered_count = render_module.render_all(bufnr, force_parse or false)

		-- 可选：返回渲染的任务数量
		return rendered_count
	end
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
	M.refresh(bufnr, true) -- ⭐ 强制重新解析
	return changed
end

function M.insert_task(text, indent_extra, bufnr)
	local operations = get_module("operations")
	local result = operations.insert_task(text, indent_extra, bufnr, M)
	M.refresh(bufnr, true) -- ⭐ 强制重新解析
	return result
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
		-- 使用模块管理器重新加载模块
		module.reload("ui." .. name)
		modules[name] = nil
	end
	-- 重新加载 ui 模块自身
	module.reload("ui")

	-- 重新获取模块
	window_switcher = nil

	return module.get("ui")
end

return M
