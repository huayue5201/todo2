-- lua/todo2/ui/init.lua
local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
-- 核心模块直接加载
local config = require("todo2.config")

-- UI 子模块直接加载
local ui_highlights = require("todo2.ui.highlights")
local ui_conceal = require("todo2.ui.conceal")
local ui_file_manager = require("todo2.ui.file_manager")
local ui_render = require("todo2.ui.render")

---------------------------------------------------------------------
-- UI 初始化
---------------------------------------------------------------------
function M.setup()
	if ui_highlights.setup then
		ui_highlights.setup()
	end

	M.setup_window_autocmds()

	return M
end

function M.setup_highlights()
	if ui_highlights.setup then
		ui_highlights.setup()
	end
end

---------------------------------------------------------------------
-- 设置窗口切换自动命令
---------------------------------------------------------------------
local window_autocmd_group = nil

function M.setup_window_autocmds()
	if window_autocmd_group then
		vim.api.nvim_del_augroup_by_id(window_autocmd_group)
	end

	window_autocmd_group = vim.api.nvim_create_augroup("Todo2WindowMonitor", { clear = true })

	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = window_autocmd_group,
		callback = function(args)
			if args.buf and args.buf ~= 0 then
				M.on_buf_win_enter(args.buf)
			end
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

	if vim.api.nvim_buf_is_valid(bufnr) then
		M.safe_reapply_smart_conceal(bufnr)
	end
end

function M.is_todo_buffer(bufnr)
	if not bufnr or bufnr == 0 then
		return false
	end

	local filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")
	if filetype == "todo" then
		return true
	end

	local buf_name = vim.api.nvim_buf_get_name(bufnr)
	if buf_name:match("todo") then
		return true
	end

	local ok, is_todo = pcall(vim.api.nvim_buf_get_var, bufnr, "todo2_file")
	if ok and is_todo then
		return true
	end

	return false
end

---------------------------------------------------------------------
-- 通知功能
---------------------------------------------------------------------
function M.show_notification(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- 刷新逻辑
---------------------------------------------------------------------
function M.refresh(bufnr, force_parse)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	local rendered_count = 0

	-- ⭐ 改用新的统一入口 render()，并正确传递 force_refresh 参数
	if ui_render and ui_render.render then
		rendered_count = ui_render.render(bufnr, {
			force_refresh = force_parse or false,
		})
	end

	-- 渲染成功后重新应用 conceal（保持不变）
	if rendered_count > 0 and ui_conceal.apply_smart_conceal then
		ui_conceal.apply_smart_conceal(bufnr)
	end

	return rendered_count
end

---------------------------------------------------------------------
-- 公开API（核心修复：返回buf+win、中文路径转义）
---------------------------------------------------------------------
function M.open_todo_file(path, mode, line_number, opts)
	local ui_window = require("todo2.ui.window")

	opts = opts or {}
	local enter_insert = opts.enter_insert ~= false
	local split_direction = opts.split_direction or "horizontal"

	-- 核心修复1：强制转义中文路径
	path = vim.fn.fnamemodify(vim.fn.expand(path, ":p"), ":p")

	if vim.fn.filereadable(path) == 0 then
		M.show_notification("TODO文件不存在: " .. path, vim.log.levels.ERROR)
		return nil, nil -- 统一返回两个值
	end

	line_number = line_number or 1

	if ui_window then
		if mode == "float" then
			-- 核心修复2：接收bufnr和win两个返回值
			local bufnr, win = ui_window.show_floating(path, line_number, enter_insert, M)
			if bufnr and bufnr > 0 then
				pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
			end
			return bufnr, win -- 返回buf+win
		elseif mode == "split" then
			local bufnr, win = ui_window.show_split(path, line_number, enter_insert, split_direction, M)
			if bufnr and bufnr > 0 then
				pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
			end
			return bufnr, win
		end
	end

	-- 默认编辑模式
	local bufnr = ui_window and ui_window.show_edit(path, line_number, enter_insert, M) or nil
	local win = bufnr and vim.api.nvim_get_current_win() or nil
	if bufnr and bufnr > 0 then
		pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
	end
	return bufnr, win
end

function M.select_todo_file(scope, callback)
	if ui_file_manager and ui_file_manager.select_todo_file then
		return ui_file_manager.select_todo_file(scope, callback)
	end
	M.show_notification("文件管理器模块未加载", vim.log.levels.ERROR)
end

function M.create_todo_file()
	if ui_file_manager and ui_file_manager.create_todo_file then
		return ui_file_manager.create_todo_file()
	end
	M.show_notification("文件管理器模块未加载", vim.log.levels.ERROR)
end

function M.toggle_selected_tasks()
	local bufnr = vim.api.nvim_get_current_buf()
	local win = vim.fn.bufwinid(bufnr)

	if win == -1 then
		M.show_notification("未在窗口中找到缓冲区", vim.log.levels.ERROR)
		return 0
	end

	if ui_operations and ui_operations.toggle_selected_tasks then
		local changed = ui_operations.toggle_selected_tasks(bufnr, win)

		if changed > 0 and ui_conceal.apply_smart_conceal then
			ui_conceal.apply_smart_conceal(bufnr)
		end

		return changed
	end

	return 0
end

function M.insert_task(text, indent_extra, bufnr)
	local ui_operations = require("todo2.ui.operations")
	if not bufnr or bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end

	if ui_operations and ui_operations.insert_task then
		local result = ui_operations.insert_task(text, indent_extra, bufnr, M)

		if result then
			M.refresh(bufnr, true)
			if ui_conceal and ui_conceal.apply_smart_conceal then
				ui_conceal.apply_smart_conceal(bufnr)
			end
		end

		return result
	end

	return false
end

function M.clear_cache()
	if ui_file_manager and ui_file_manager.clear_cache then
		return ui_file_manager.clear_cache()
	end
	return false
end

function M.apply_smart_conceal(bufnr)
	if not bufnr or bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end

	if ui_conceal and ui_conceal.apply_smart_conceal then
		return ui_conceal.apply_smart_conceal(bufnr)
	end

	return false
end

function M.safe_reapply_smart_conceal(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	local winid = vim.fn.bufwinid(bufnr)
	if winid == -1 then
		return false
	end

	local ok, err = pcall(M.apply_smart_conceal, bufnr)
	if not ok then
		M.show_notification("重新应用隐藏失败: " .. tostring(err), vim.log.levels.WARN)
	end

	return ok
end

return M
