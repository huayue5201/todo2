-- lua/todo2/ui/init.lua
local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local ui_highlights = require("todo2.ui.highlights")
local ui_conceal = require("todo2.ui.conceal")
local ui_file_manager = require("todo2.ui.file_manager")
local ui_render = require("todo2.ui.render")

---------------------------------------------------------------------
-- UI 初始化
---------------------------------------------------------------------
function M.setup()
	-- 设置高亮组
	ui_highlights.setup()

	M.setup_window_autocmds()

	-- ⭐ 新增：全局监听 TODO 文件保存
	M.setup_todo_file_save_listener()

	return M
end

---------------------------------------------------------------------
-- ⭐ 新增：设置 TODO 文件保存监听
---------------------------------------------------------------------
function M.setup_todo_file_save_listener()
	local group = vim.api.nvim_create_augroup("Todo2FileSaveSync", { clear = true })

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = { "*.todo.md", "*.todo" }, -- 只监听 TODO 文件
		callback = function(args)
			-- 延迟执行，确保文件写入完成
			vim.defer_fn(function()
				M.sync_todo_file_after_save(args.file, args.buf)
			end, 50)
		end,
		desc = "TODO 文件保存后同步到 store",
	})
end

---------------------------------------------------------------------
-- ⭐ 新增：文件保存后的同步逻辑
---------------------------------------------------------------------
-- ⭐ 在 sync_todo_file_after_save 函数中，添加上下文更新
function M.sync_todo_file_after_save(filepath, bufnr)
	if not filepath or filepath == "" then
		return
	end

	-- 1. 使解析缓存失效
	local parser = require("todo2.core.parser")
	parser.invalidate_cache(filepath)

	-- 2. 同步到 store（核心！）
	local autofix = require("todo2.store.autofix")
	local report = autofix.sync_todo_links(filepath)

	-- ⭐ 新增：更新过期上下文
	local verification = require("todo2.store.verification")
	local context_report = verification.update_expired_contexts and verification.update_expired_contexts(filepath)
		or nil

	-- 3. 触发事件通知其他模块
	local events = require("todo2.core.events")
	events.on_state_changed({
		source = "todo_file_save",
		file = filepath,
		bufnr = bufnr,
		ids = report and report.ids or {},
		timestamp = os.time() * 1000,
	})

	-- 4. 刷新当前缓冲区（如果可见）
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		local win = vim.fn.bufwinid(bufnr)
		if win ~= -1 then
			M.refresh(bufnr, true, true)

			-- 显示通知（可选）
			if report and report.updated and report.updated > 0 then
				local msg = string.format("已同步 %d 个任务更新", report.updated)
				if context_report and context_report.updated and context_report.updated > 0 then
					msg = msg .. string.format("，更新 %d 个上下文", context_report.updated)
				end
				vim.notify(msg, vim.log.levels.INFO)
			end
		end
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

	local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
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
-- 刷新逻辑（增强版）
---------------------------------------------------------------------
function M.refresh(bufnr, force_parse, force_sync)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	-- ⭐ 如果需要强制同步到 store
	if force_sync then
		local path = vim.api.nvim_buf_get_name(bufnr)
		if path and (path:match("%.todo%.md$") or path:match("%.todo$")) then
			local autofix = require("todo2.store.autofix")
			autofix.sync_todo_links(path)
		end
	end

	local rendered_count = 0

	-- 使用统一渲染入口
	if ui_render and ui_render.render then
		rendered_count = ui_render.render(bufnr, {
			force_refresh = force_parse or false,
		})
	end

	-- 渲染成功后重新应用 conceal（包括删除线）
	if rendered_count > 0 and ui_conceal and ui_conceal.apply_smart_conceal then
		ui_conceal.apply_smart_conceal(bufnr)
	end

	return rendered_count
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------
function M.open_todo_file(path, mode, line_number, opts)
	local ui_window = require("todo2.ui.window")

	opts = opts or {}
	local enter_insert = opts.enter_insert ~= false
	local split_direction = opts.split_direction or "horizontal"

	-- 强制转义中文路径
	path = vim.fn.fnamemodify(vim.fn.expand(path, ":p"), ":p")

	if vim.fn.filereadable(path) == 0 then
		M.show_notification("TODO文件不存在: " .. path, vim.log.levels.ERROR)
		return nil, nil
	end

	line_number = line_number or 1

	if ui_window then
		if mode == "float" then
			-- ⭐ 传递 M 作为 ui_module
			local bufnr, win = ui_window.show_floating(path, line_number, enter_insert, M)
			if bufnr and bufnr > 0 then
				pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
			end
			return bufnr, win
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

function M.delete_todo_file(path)
	if ui_file_manager and ui_file_manager.delete_todo_file then
		return ui_file_manager.delete_todo_file(path)
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

	-- ⭐ 延迟加载 ui_operations，避免循环依赖
	local ui_operations = require("todo2.ui.operations")
	if ui_operations and ui_operations.toggle_selected_tasks then
		local changed = ui_operations.toggle_selected_tasks(bufnr, win)

		if changed > 0 and ui_conceal and ui_conceal.apply_smart_conceal then
			ui_conceal.apply_smart_conceal(bufnr)
		end

		return changed
	end

	return 0
end

function M.insert_task(text, indent_extra, bufnr)
	-- ⭐ 延迟加载 ui_operations
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
