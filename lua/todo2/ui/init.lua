-- lua/todo2/ui/init.lua
local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local ui_highlights = require("todo2.ui.highlights")
local ui_conceal = require("todo2.ui.conceal")
local ui_file_manager = require("todo2.ui.file_manager")
local ui_render = require("todo2.ui.render")

---------------------------------------------------------------------
-- 配置（默认值）
---------------------------------------------------------------------
local config = {
	float_reuse_strategy = "file", -- "file", "global", "none"
}

---------------------------------------------------------------------
-- UI 初始化
---------------------------------------------------------------------
function M.setup(user_config)
	-- 合并用户配置
	if user_config and user_config.ui then
		config = vim.tbl_deep_extend("force", config, user_config.ui)
	end

	-- 设置高亮组
	ui_highlights.setup()

	M.setup_window_autocmds()
	M.setup_todo_file_save_listener()

	return M
end

---------------------------------------------------------------------
-- 文件保存监听
---------------------------------------------------------------------
function M.setup_todo_file_save_listener()
	local group = vim.api.nvim_create_augroup("Todo2FileSaveSync", { clear = true })

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = { "*.todo.md", "*.todo" },
		callback = function(args)
			vim.defer_fn(function()
				M.sync_todo_file_after_save(args.file, args.buf)
			end, 50)
		end,
		desc = "TODO 文件保存后同步到 store",
	})
end

function M.sync_todo_file_after_save(filepath, bufnr)
	if not filepath or filepath == "" then
		return
	end

	-- 1. 使解析缓存失效
	local parser = require("todo2.core.parser")
	parser.invalidate_cache(filepath)

	-- 2. 同步到 store
	local autofix = require("todo2.store.autofix")
	local report = autofix.sync_todo_links(filepath)

	-- 3. 更新过期上下文
	local verification = require("todo2.store.verification")
	local context_report = verification.update_expired_contexts and verification.update_expired_contexts(filepath)
		or nil

	-- 4. 触发事件
	local events = require("todo2.core.events")
	events.on_state_changed({
		source = "todo_file_save",
		file = filepath,
		bufnr = bufnr,
		ids = report and report.ids or {},
		timestamp = os.time() * 1000,
	})

	-- 5. 刷新当前缓冲区
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		local win = vim.fn.bufwinid(bufnr)
		if win ~= -1 then
			-- 全量刷新
			M.refresh(bufnr)

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
-- 简化版刷新逻辑
---------------------------------------------------------------------
function M.refresh(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	local rendered_count = 0

	-- 使用简化后的渲染模块
	if ui_render and ui_render.render then
		rendered_count = ui_render.render(bufnr)
	end

	-- 渲染成功后重新应用 conceal
	if rendered_count > 0 and ui_conceal and ui_conceal.apply_smart_conceal then
		ui_conceal.apply_smart_conceal(bufnr)
	end

	return rendered_count
end

---------------------------------------------------------------------
-- ⭐ 修改：打开 TODO 文件，支持复用策略
---------------------------------------------------------------------
function M.open_todo_file(path, mode, line_number, opts)
	local ui_window = require("todo2.ui.window")

	opts = opts or {}
	local enter_insert = opts.enter_insert ~= false
	local split_direction = opts.split_direction or "horizontal"

	-- ⭐ 获取复用策略：优先使用 opts 传入的，否则使用配置的
	local reuse_strategy = opts.reuse_strategy or config.float_reuse_strategy

	path = vim.fn.fnamemodify(vim.fn.expand(path, ":p"), ":p")

	if vim.fn.filereadable(path) == 0 then
		M.show_notification("TODO文件不存在: " .. path, vim.log.levels.ERROR)
		return nil, nil
	end

	line_number = line_number or 1

	if ui_window then
		if mode == "float" then
			-- ⭐ 根据策略选择不同的复用方式
			if reuse_strategy == "global" then
				-- 全局单浮窗模式
				return ui_window.find_or_create_global_float(path, line_number, enter_insert, M)
			elseif reuse_strategy == "file" then
				-- 按文件复用
				local existing_win = ui_window.find_existing_float(path)
				if existing_win then
					local bufnr = vim.api.nvim_win_get_buf(existing_win)
					vim.api.nvim_set_current_win(existing_win)
					if line_number then
						vim.api.nvim_win_set_cursor(existing_win, { line_number, 0 })
					end
					if enter_insert then
						vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
					end
					vim.notify("已跳转到已打开的 TODO 文件", vim.log.levels.INFO)
					return bufnr, existing_win
				end
			end
			-- reuse_strategy == "none" 或没有找到现有窗口，创建新浮窗
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

	local bufnr = ui_window and ui_window.show_edit(path, line_number, enter_insert, M) or nil
	local win = bufnr and vim.api.nvim_get_current_win() or nil
	if bufnr and bufnr > 0 then
		pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
	end
	return bufnr, win
end

---------------------------------------------------------------------
-- ⭐ 新增：关闭所有 TODO 浮窗
---------------------------------------------------------------------
function M.close_all_floats()
	local ui_window = require("todo2.ui.window")
	local closed_count = 0

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local config = vim.api.nvim_win_get_config(win)
		if config.relative ~= "" and config.relative ~= nil then
			local buf = vim.api.nvim_win_get_buf(win)
			local buf_name = vim.api.nvim_buf_get_name(buf)
			if buf_name:match("%.todo%.md$") then
				pcall(vim.api.nvim_win_close, win, true)
				closed_count = closed_count + 1
			end
		end
	end

	if closed_count > 0 then
		vim.notify(string.format("已关闭 %d 个 TODO 浮窗", closed_count), vim.log.levels.INFO)
	end
end

---------------------------------------------------------------------
-- ⭐ 新增：列出所有打开的 TODO 文件
---------------------------------------------------------------------
function M.list_open_todo_files()
	local ui_window = require("todo2.ui.window")
	local open_files = {}

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		local buf_name = vim.api.nvim_buf_get_name(buf)
		if buf_name:match("%.todo%.md$") then
			local config = vim.api.nvim_win_get_config(win)
			table.insert(open_files, {
				path = buf_name,
				filename = vim.fn.fnamemodify(buf_name, ":t"),
				win = win,
				is_float = config.relative ~= "" and config.relative ~= nil,
			})
		end
	end

	return open_files
end

---------------------------------------------------------------------
-- 以下函数保持不变
---------------------------------------------------------------------
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
