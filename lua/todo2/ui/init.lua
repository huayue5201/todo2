-- lua/todo2/ui/init.lua
--- @module todo2.ui

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 模块依赖声明
---------------------------------------------------------------------
M.dependencies = {
	"config",
	"core",
	"link",
}

---------------------------------------------------------------------
-- 检查并加载依赖
---------------------------------------------------------------------
local function load_dependencies()
	for _, dep in ipairs(M.dependencies) do
		if not module.is_loaded(dep) then
			module.get(dep)
		end
	end
end

---------------------------------------------------------------------
-- UI 初始化
---------------------------------------------------------------------
function M.setup()
	load_dependencies()

	-- 1. 设置高亮
	M.setup_highlights()

	-- 2. 设置全局按键映射
	M.setup_global_keymaps()

	return M
end

function M.setup_highlights()
	load_dependencies()
	local highlights = module.get("ui.highlights")
	if highlights and highlights.setup then
		highlights.setup()
	end
end

---------------------------------------------------------------------
-- 通知功能
---------------------------------------------------------------------
function M.show_notification(msg, level)
	level = level or vim.log.levels.INFO
	vim.notify(msg, level)
end

---------------------------------------------------------------------
-- ⭐ 增强版刷新逻辑：支持强制重新解析
---------------------------------------------------------------------
function M.refresh(bufnr, force_parse)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	load_dependencies()

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
-- 打开 TODO 文件
---------------------------------------------------------------------
function M.open_todo_file(path, mode, line_number, opts)
	load_dependencies()

	opts = opts or {}
	local enter_insert = opts.enter_insert ~= false
	local split_direction = opts.split_direction or "horizontal"

	path = vim.fn.fnamemodify(path, ":p")

	if vim.fn.filereadable(path) == 0 then
		M.show_notification("TODO文件不存在: " .. path, vim.log.levels.ERROR)
		return
	end

	line_number = line_number or 1

	local window = module.get("ui.window")
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
-- 公开 API
---------------------------------------------------------------------
function M.select_todo_file(scope, callback)
	load_dependencies()
	return module.get("ui.file_manager").select_todo_file(scope, callback)
end

function M.create_todo_file()
	load_dependencies()
	return module.get("ui.file_manager").create_todo_file()
end

function M.delete_todo_file(path)
	load_dependencies()
	return module.get("ui.file_manager").delete_todo_file(path)
end

function M.toggle_selected_tasks()
	load_dependencies()

	local bufnr = vim.api.nvim_get_current_buf()
	local win = vim.fn.bufwinid(bufnr)

	if win == -1 then
		M.show_notification("未在窗口中找到缓冲区", vim.log.levels.ERROR)
		return 0
	end

	local operations = module.get("ui.operations")
	local changed = operations.toggle_selected_tasks(bufnr, win)

	-- ⭐ 不再强制刷新，由事件系统自动刷新
	return changed
end

function M.insert_task(text, indent_extra, bufnr)
	load_dependencies()

	local operations = module.get("ui.operations")
	local result = operations.insert_task(text, indent_extra, bufnr, M)

	-- ⭐ 不再强制刷新，由事件系统自动刷新
	return result
end

function M.insert_task(text, indent_extra, bufnr)
	load_dependencies()

	local operations = module.get("ui.operations")
	local result = operations.insert_task(text, indent_extra, bufnr, M)
	M.refresh(bufnr, true) -- ⭐ 强制重新解析
	return result
end

function M.clear_cache()
	load_dependencies()
	return module.get("ui.file_manager").clear_cache()
end

function M.apply_conceal(bufnr)
	load_dependencies()
	return module.get("ui.conceal").apply_conceal(bufnr)
end

function M.get_window_module()
	load_dependencies()
	return module.get("ui.window")
end

function M.get_keymaps_module()
	load_dependencies()
	return module.get("ui.keymaps")
end

function M.setup_global_keymaps()
	load_dependencies()
	local keymaps = module.get("ui.keymaps")
	if keymaps and keymaps.setup_global_keymaps then
		keymaps.setup_global_keymaps()
	end
end

function M.reload_modules()
	for name, _ in pairs(module._cache) do
		if name:match("^ui%.") then
			module.reload(name)
		end
	end

	module.reload("ui")
	return module.get("ui")
end

return M
