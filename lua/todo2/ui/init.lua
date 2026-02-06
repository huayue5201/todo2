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
local _deps_loaded = false

local function load_dependencies()
	if _deps_loaded then
		return
	end

	for _, dep in ipairs(M.dependencies) do
		if not module.is_loaded(dep) then
			module.get(dep)
		end
	end

	_deps_loaded = true
end

---------------------------------------------------------------------
-- UI 初始化
---------------------------------------------------------------------
function M.setup()
	load_dependencies()

	-- 设置高亮
	M.setup_highlights()

	-- 设置窗口切换事件监听
	M.setup_window_autocmds()

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
-- 设置窗口切换自动命令
---------------------------------------------------------------------
local _window_autocmd_group = nil

function M.setup_window_autocmds()
	if _window_autocmd_group then
		-- 已经设置过了，先清理
		vim.api.nvim_del_augroup_by_id(_window_autocmd_group)
	end

	_window_autocmd_group = vim.api.nvim_create_augroup("Todo2WindowMonitor", { clear = true })

	-- 监听缓冲区窗口进入事件
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = _window_autocmd_group,
		callback = function(args)
			M.on_buf_win_enter(args.buf)
		end,
		desc = "TODO 缓冲区进入窗口时应用 conceal",
	})
end

---------------------------------------------------------------------
-- 窗口事件处理函数
---------------------------------------------------------------------
function M.on_buf_win_enter(bufnr)
	if not bufnr or bufnr == 0 then
		return
	end

	-- 检查是否是 TODO 缓冲区
	if M.is_todo_buffer(bufnr) then
		-- 延迟应用，确保窗口完全加载
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				M.safe_reapply_conceal(bufnr)
			end
		end, 100)
	end
end

-- 检查是否是 TODO 缓冲区
function M.is_todo_buffer(bufnr)
	if not bufnr or bufnr == 0 then
		return false
	end

	-- 检查文件名是否包含 todo
	local buf_name = vim.api.nvim_buf_get_name(bufnr)
	if buf_name:match("todo") then
		return true
	end

	-- 检查缓冲区变量（如果有设置）
	local success, is_todo = pcall(vim.api.nvim_buf_get_var, bufnr, "todo2_file")
	if success and is_todo then
		return true
	end

	-- 检查文件类型
	local filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")
	if filetype == "todo" then
		return true
	end

	return false
end

---------------------------------------------------------------------
-- 通知功能
---------------------------------------------------------------------
function M.show_notification(msg, level)
	level = level or vim.log.levels.INFO
	vim.notify(msg, level)
end

---------------------------------------------------------------------
-- 刷新逻辑（简化版）
---------------------------------------------------------------------
function M.refresh(bufnr, force_parse)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	load_dependencies()

	-- 使用模块管理器获取 render 模块
	local render_module = module.get("ui.render")
	local conceal_module = module.get("ui.conceal")

	local rendered_count = 0

	-- 渲染任务
	if render_module and render_module.render_with_core then
		rendered_count = render_module.render_with_core(bufnr, {
			force_refresh = force_parse or false,
			incremental = true, -- 使用增量渲染
		})
	end

	-- 渲染完成后应用conceal设置
	if rendered_count > 0 and conceal_module then
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				conceal_module.apply_smart_conceal(bufnr)
			end
		end, 50)
	end

	return rendered_count
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
		local bufnr = window.show_floating(path, line_number, enter_insert, M)
		if bufnr and bufnr > 0 then
			-- 标记为 TODO 文件
			pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
		end
		return bufnr
	elseif mode == "split" then
		local bufnr = window.show_split(path, line_number, enter_insert, split_direction, M)
		if bufnr and bufnr > 0 then
			pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
		end
		return bufnr
	elseif mode == "edit" then
		local bufnr = window.show_edit(path, line_number, enter_insert, M)
		if bufnr and bufnr > 0 then
			pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
		end
		return bufnr
	else
		local bufnr = window.show_edit(path, line_number, enter_insert, M)
		if bufnr and bufnr > 0 then
			pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
		end
		return bufnr
	end
end

---------------------------------------------------------------------
-- 公开 API（只保留外部真正会用的）
---------------------------------------------------------------------
function M.select_todo_file(scope, callback)
	load_dependencies()
	return module.get("ui.file_manager").select_todo_file(scope, callback)
end

function M.create_todo_file()
	load_dependencies()
	return module.get("ui.file_manager").create_todo_file()
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

	-- 切换任务后重新应用 conceal
	if changed > 0 then
		local conceal_module = module.get("ui.conceal")
		if conceal_module and conceal_module.apply_smart_conceal then
			conceal_module.apply_smart_conceal(bufnr)
		end
	end

	return changed
end

function M.insert_task(text, indent_extra, bufnr)
	load_dependencies()

	local operations = module.get("ui.operations")
	local result = operations.insert_task(text, indent_extra, bufnr, M)

	-- 插入任务后刷新并应用 conceal
	if result then
		local conceal_module = module.get("ui.conceal")
		M.refresh(bufnr, true)
		if conceal_module and conceal_module.apply_smart_conceal then
			vim.defer_fn(function()
				if vim.api.nvim_buf_is_valid(bufnr) then
					conceal_module.apply_smart_conceal(bufnr)
				end
			end, 50)
		end
	end

	return result
end

function M.clear_cache()
	load_dependencies()
	return module.get("ui.file_manager").clear_cache()
end

function M.apply_conceal(bufnr)
	load_dependencies()
	local conceal_module = module.get("ui.conceal")
	if conceal_module and conceal_module.apply_smart_conceal then
		return conceal_module.apply_smart_conceal(bufnr)
	end
	return false
end

function M.reload_modules()
	-- 重置依赖加载状态
	_deps_loaded = false

	for name, _ in pairs(module._cache) do
		if name:match("^ui%.") then
			module.reload(name)
		end
	end

	module.reload("ui")

	-- 重新设置自动命令
	M.setup_window_autocmds()

	return module.get("ui")
end

-- 安全地重新应用 conceal（简化版）
function M.safe_reapply_conceal(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	-- 检查缓冲区是否在窗口中
	local winid = vim.fn.bufwinid(bufnr)
	if winid == -1 then
		return false -- 缓冲区不在窗口中
	end

	-- 延迟应用，确保窗口已完全加载
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(bufnr) and vim.fn.bufwinid(bufnr) ~= -1 then
			-- 使用 pcall 安全调用
			local success, err = pcall(M.apply_conceal, bufnr)
			if not success then
				M.show_notification("重新应用 conceal 失败: " .. tostring(err), vim.log.levels.WARN)
			end
		end
	end, 20)

	return true
end

return M
