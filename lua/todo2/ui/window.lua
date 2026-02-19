-- File: /Users/lijia/todo2/lua/todo2/ui/window.lua
-- lua/todo2/ui/window.lua
--- @module todo2.ui.window
--- ⭐ 增强：添加上下文指纹支持

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local core = require("todo2.core")
local conceal = require("todo2.ui.conceal")
local statistics = require("todo2.ui.statistics")
local keymaps = require("todo2.keymaps")
local parser = require("todo2.core.parser")

---------------------------------------------------------------------
-- 内部缓存
---------------------------------------------------------------------
local _window_cache = {}
local _file_content_cache = {
	max_size = 5,
	data = {},
}

---------------------------------------------------------------------
-- 工具函数：安全处理路径
---------------------------------------------------------------------
local function safe_path(path)
	if type(path) ~= "string" then
		return nil
	end
	local norm_path = vim.fn.fnamemodify(vim.fn.expand(path, ":p"), ":p")
	return norm_path ~= "" and norm_path or nil
end

---------------------------------------------------------------------
-- 获取缓存的文件内容
---------------------------------------------------------------------
local function get_cached_file_content(path)
	path = safe_path(path)
	if not path then
		vim.notify("无效的文件路径", vim.log.levels.ERROR)
		return nil
	end

	if _file_content_cache.data[path] then
		return _file_content_cache.data[path]
	end

	local ok, content = pcall(function()
		local fd = vim.loop.fs_open(path, "r", 438)
		if not fd then
			return nil
		end
		local stat = vim.loop.fs_fstat(fd)
		local data = vim.loop.fs_read(fd, stat.size, 0)
		vim.loop.fs_close(fd)
		return vim.split(data, "\n")
	end)

	if not ok or not content then
		vim.notify("无法读取文件内容: " .. path, vim.log.levels.ERROR)
		return nil
	end

	local keys = vim.tbl_keys(_file_content_cache.data)
	if #keys >= _file_content_cache.max_size then
		_file_content_cache.data[keys[1]] = nil
	end

	_file_content_cache.data[path] = content
	return content
end

---------------------------------------------------------------------
-- ⭐ 内部函数：创建浮动窗口（增强版：添加上下文更新监听）
---------------------------------------------------------------------
local function create_floating_window(bufnr, path, ui_module)
	if type(bufnr) ~= "number" or bufnr < 1 then
		vim.notify("无效的缓冲区ID: " .. tostring(bufnr), vim.log.levels.ERROR)
		return nil
	end

	path = safe_path(path)
	if not path then
		return nil
	end

	if not core or not conceal then
		vim.notify("核心模块/隐藏模块未加载", vim.log.levels.ERROR)
		return nil
	end

	local lines = get_cached_file_content(path)
	if not lines then
		return nil
	end

	local width = math.min(math.floor(vim.o.columns * 0.8), 140)
	local height = math.min(30, math.max(10, #lines + 4))
	local col = math.floor((vim.o.columns - width) / 2)
	local row = math.floor((vim.o.lines - height) / 2)

	local ok, win = pcall(vim.api.nvim_open_win, bufnr, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		border = "rounded",
		title = "📋 TODO - " .. vim.fn.fnamemodify(path, ":t"),
		style = "minimal",
	})

	if not ok or not win or win == 0 then
		vim.notify("创建浮窗失败: " .. tostring(win) .. " | 路径: " .. path, vim.log.levels.ERROR)
		return nil
	end

	conceal.apply_smart_conceal(bufnr)

	_window_cache[bufnr] = {
		win = win,
		path = path,
		update_summary = nil,
	}

	local function update_summary()
		if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end

		local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local filepath = vim.api.nvim_buf_get_name(bufnr)

		local ok, _ = pcall(parser.parse_file, filepath, true)
		if not ok then
			vim.notify("解析文件失败: " .. filepath, vim.log.levels.WARN)
		end

		local stat = core.summarize(current_lines, filepath)
		local footer_text = statistics and statistics.format_summary(stat) or "暂无统计"

		pcall(vim.api.nvim_win_set_config, win, {
			footer = { { " " .. footer_text .. " ", "Number" } },
			footer_pos = "right",
		})
	end

	_window_cache[bufnr].update_summary = update_summary

	-- 直接使用已导入的 keymaps 模块
	keymaps.bind_for_context(bufnr, "markdown", true)

	-- ⭐ 新增：监听文件保存，自动刷新数据并更新上下文
	local save_group = vim.api.nvim_create_augroup("Todo2FloatSaveRefresh_" .. bufnr, { clear = true })
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = save_group,
		buffer = bufnr,
		callback = function()
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(bufnr) then
					return
				end

				-- 1. 使解析缓存失效
				parser.invalidate_cache(path)

				-- 2. 同步到 store
				local autofix = require("todo2.store.autofix")
				local report = autofix.sync_todo_links(path)

				-- ⭐ 3. 更新过期上下文
				local verification = require("todo2.store.verification")
				local context_report = nil
				if verification and verification.update_expired_contexts then
					context_report = verification.update_expired_contexts(path)
				end

				-- 4. 刷新 UI
				if ui_module and ui_module.refresh then
					ui_module.refresh(bufnr, true, true)
				end

				-- 5. 重新应用 conceal
				conceal.apply_smart_conceal(bufnr)

				-- 6. 更新统计
				update_summary()

				-- 7. 显示通知
				if report and report.updated and report.updated > 0 then
					local msg = string.format("✅ 已同步 %d 个任务更新", report.updated)
					if context_report and context_report.updated and context_report.updated > 0 then
						msg = msg .. string.format("，更新 %d 个上下文", context_report.updated)
					end
					vim.notify(msg, vim.log.levels.INFO)
				end
			end)
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = bufnr,
		callback = function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			update_summary()
			local event_type = vim.v.event and vim.v.event.input_type or "typing"
			local mode = (event_type == "paste") and "paste" or "typing"
			if ui_module and type(ui_module.schedule_refresh) == "function" then
				ui_module.schedule_refresh(bufnr, { mode = mode, priority = 100 })
			end
		end,
	})

	return win, update_summary
end

---------------------------------------------------------------------
-- 独立帮助浮窗（完全兼容各版本 Neovim）
--- 创建底部帮助浮窗，紧贴主窗口底部
--- @param main_win integer 主窗口句柄
--- @param main_buf integer 主缓冲区句柄
--- @param width number 宽度（与主窗口一致）
--- @param hint string 帮助文本
--- @return integer footer_win, integer footer_buf
---------------------------------------------------------------------
local function create_footer_window(main_win, main_buf, width, hint)
	local main_config = vim.api.nvim_win_get_config(main_win)

	-- 安全获取 row/col/height，兼容数字和表两种格式
	local function get_config_value(val)
		if type(val) == "table" then
			return val[1]
		end
		return val
	end

	local row = get_config_value(main_config.row)
	local col = get_config_value(main_config.col)
	local height = get_config_value(main_config.height)

	local new_row = row + height + 2

	-- 创建帮助缓冲区
	local footer_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = footer_buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = footer_buf })
	vim.api.nvim_set_option_value("modifiable", true, { buf = footer_buf })

	-- 写入帮助文本
	vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, { hint })

	-- 设置高亮（使用 extmark）
	local ns = vim.api.nvim_create_namespace("todo2_creation_hint")
	vim.api.nvim_buf_clear_namespace(footer_buf, ns, 0, -1)
	vim.api.nvim_buf_set_extmark(footer_buf, ns, 0, 0, {
		hl_group = "Todo2CreationHint",
		end_col = #hint,
		hl_eol = true,
	})
	vim.api.nvim_set_option_value("modifiable", false, { buf = footer_buf })

	-- 创建浮动窗口（不可聚焦）
	local footer_win = vim.api.nvim_open_win(footer_buf, false, {
		relative = "editor",
		width = width,
		height = 1,
		col = col,
		row = new_row,
		style = "minimal",
		border = "rounded",
		title = " Help ",
		title_pos = "center",
		focusable = false,
		zindex = main_config.zindex + 1,
	})

	-- 设置高亮组（若未定义）
	vim.cmd("highlight default link Todo2CreationHint Comment")

	-- 自动关闭：当主窗口关闭时，同时关闭帮助窗
	vim.api.nvim_create_autocmd("WinClosed", {
		buffer = main_buf,
		once = true,
		callback = function()
			pcall(vim.api.nvim_win_close, footer_win, true)
		end,
	})

	-- 自动调整位置：当主窗口移动/大小时跟随
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		callback = function()
			if vim.api.nvim_win_is_valid(main_win) and vim.api.nvim_win_is_valid(footer_win) then
				local new_config = vim.api.nvim_win_get_config(main_win)
				local new_row = get_config_value(new_config.row) + get_config_value(new_config.height) + 1
				pcall(vim.api.nvim_win_set_config, footer_win, {
					row = new_row,
					col = get_config_value(new_config.col),
				})
			end
		end,
	})

	return footer_win, footer_buf
end

---------------------------------------------------------------------
-- 浮动窗口模式
---------------------------------------------------------------------
function M.show_floating(path, line_number, enter_insert, ui_module)
	path = safe_path(path)
	if not path then
		vim.notify("无效的文件路径（非字符串）", vim.log.levels.ERROR)
		return nil, nil
	end

	local ok, bufnr = pcall(function()
		local b = vim.fn.bufnr(path)
		if b == -1 then
			b = vim.fn.bufadd(path)
			vim.fn.bufload(b)
		end
		return b
	end)

	if not ok or not bufnr or bufnr == -1 then
		vim.notify("加载缓冲区失败: " .. tostring(bufnr) .. " | 路径: " .. path, vim.log.levels.ERROR)
		return nil, nil
	end

	local buf_opts = {
		buftype = "",
		bufhidden = "wipe",
		modifiable = true,
		readonly = false,
		swapfile = false,
		filetype = "markdown",
		fileencoding = "utf-8",
	}

	if vim.api.nvim_buf_is_valid(bufnr) then
		for opt, val in pairs(buf_opts) do
			local success, err = pcall(function()
				vim.bo[bufnr][opt] = val
			end)
			if not success then
				vim.notify(string.format("设置缓冲区选项 %s 失败: %s", opt, err), vim.log.levels.WARN)
			end
		end
	else
		vim.notify("缓冲区无效: " .. tostring(bufnr), vim.log.levels.ERROR)
		return nil, nil
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("缓冲区无效: " .. tostring(bufnr), vim.log.levels.ERROR)
		return nil, nil
	end

	local win, update_summary = create_floating_window(bufnr, path, ui_module)
	if not win then
		return nil, nil
	end

	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(bufnr) and ui_module and type(ui_module.refresh) == "function" then
			ui_module.refresh(bufnr)
		end
		if update_summary then
			update_summary()
		end

		line_number = type(line_number) == "number" and line_number or 1
		if line_number and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_cursor(win, { line_number, 0 })
			vim.api.nvim_win_call(win, function() end)
			if enter_insert then
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
			end
		end
	end, 50)

	return bufnr, win
end

---------------------------------------------------------------------
-- 分割窗口模式
---------------------------------------------------------------------
function M.show_split(path, line_number, enter_insert, split_direction, ui_module)
	path = safe_path(path)
	if not path then
		vim.notify("无效的文件路径", vim.log.levels.ERROR)
		return nil, nil
	end

	local current_win = vim.api.nvim_get_current_win()

	if split_direction == "vertical" or split_direction == "v" then
		vim.cmd("vsplit")
	else
		vim.cmd("split")
	end

	local new_win = vim.api.nvim_get_current_win()
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	local bufnr = vim.api.nvim_get_current_buf()

	local buf_opts = {
		buftype = "",
		modifiable = true,
		readonly = false,
		swapfile = false,
		filetype = "markdown",
		fileencoding = "utf-8",
	}

	for opt, val in pairs(buf_opts) do
		pcall(function()
			vim.bo[bufnr][opt] = val
		end)
	end

	_window_cache[bufnr] = {
		win = new_win,
		path = path,
	}

	if conceal then
		conceal.apply_smart_conceal(bufnr)
	end

	if vim.api.nvim_buf_is_valid(bufnr) and ui_module and type(ui_module.refresh) == "function" then
		ui_module.refresh(bufnr)
	end

	line_number = type(line_number) == "number" and line_number or 1
	if line_number and vim.api.nvim_win_is_valid(new_win) then
		vim.api.nvim_win_set_cursor(new_win, { line_number, 0 })
		vim.api.nvim_win_call(new_win, function() end)
	end

	-- 直接使用已导入的 keymaps 模块
	keymaps.bind_for_context(bufnr, "markdown", false)

	if ui_module and type(ui_module.schedule_refresh) == "function" then
		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
			buffer = bufnr,
			callback = function()
				if not vim.api.nvim_buf_is_valid(bufnr) then
					return
				end
				local event_type = vim.v.event and vim.v.event.input_type or "typing"
				local mode = (event_type == "paste") and "paste" or "typing"
				ui_module.schedule_refresh(bufnr, { mode = mode, priority = 100 })
			end,
		})
	end

	if enter_insert then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	return bufnr, new_win
end

---------------------------------------------------------------------
-- 编辑模式
---------------------------------------------------------------------
function M.show_edit(path, line_number, enter_insert, ui_module)
	path = safe_path(path)
	if not path then
		vim.notify("无效的文件路径", vim.log.levels.ERROR)
		return nil
	end

	vim.cmd("edit " .. vim.fn.fnameescape(path))
	local bufnr = vim.api.nvim_get_current_buf()

	local buf_opts = {
		buftype = "",
		modifiable = true,
		readonly = false,
		swapfile = false,
		filetype = "markdown",
		fileencoding = "utf-8",
	}

	for opt, val in pairs(buf_opts) do
		pcall(function()
			vim.bo[bufnr][opt] = val
		end)
	end

	_window_cache[bufnr] = {
		win = vim.api.nvim_get_current_win(),
		path = path,
	}

	if conceal then
		conceal.apply_smart_conceal(bufnr)
	end

	if vim.api.nvim_buf_is_valid(bufnr) and ui_module and type(ui_module.refresh) == "function" then
		ui_module.refresh(bufnr)
	end

	line_number = type(line_number) == "number" and line_number or 1
	if line_number then
		vim.fn.cursor(line_number, 1)
	end

	-- 直接使用已导入的 keymaps 模块
	keymaps.bind_for_context(bufnr, "markdown", false)

	if ui_module and type(ui_module.schedule_refresh) == "function" then
		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
			buffer = bufnr,
			callback = function()
				if not vim.api.nvim_buf_is_valid(bufnr) then
					return
				end
				local event_type = vim.v.event and vim.v.event.input_type or "typing"
				local mode = (event_type == "paste") and "paste" or "typing"
				ui_module.schedule_refresh(bufnr, { mode = mode, priority = 100 })
			end,
		})
	end

	if enter_insert then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	return bufnr
end

---------------------------------------------------------------------
-- 打开窗口并绑定多个临时操作（自动清理）
--- @param path string 文件路径
--- @param opts table
---   - type: "float"|"split"|"edit"
---   - line: number 初始行
---   - enter_insert: boolean
---   - actions: table { 动作名 = { key, callback, desc, once? } }
---   - show_hint: boolean 是否在窗口底部显示按键提示
--- @return bufnr, winid
---------------------------------------------------------------------
function M.open_with_actions(path, opts)
	opts = opts or {}
	local bufnr, winid

	-- 1. 根据 type 调用现有窗口函数
	if opts.type == "float" then
		bufnr, winid = M.show_floating(path, opts.line, opts.enter_insert, opts.ui_module)
	elseif opts.type == "split" then
		bufnr, winid = M.show_split(path, opts.line, opts.enter_insert, opts.split_direction, opts.ui_module)
	else
		bufnr = M.show_edit(path, opts.line, opts.enter_insert, opts.ui_module)
		winid = vim.fn.bufwinid(bufnr)
	end

	if not bufnr or not winid then
		return nil, nil
	end

	-- 2. 绑定所有动作
	local bound_keys = {}
	for name, action in pairs(opts.actions or {}) do
		local key = action.key
		if key and action.callback then
			vim.keymap.set("n", key, function()
				action.callback({
					bufnr = bufnr,
					winid = winid,
					line = vim.api.nvim_win_get_cursor(winid)[1],
					name = name,
				})
				if action.once ~= false then
					pcall(vim.keymap.del, "n", key, { buffer = bufnr })
				end
			end, {
				buffer = bufnr,
				noremap = true,
				silent = true,
				nowait = true,
				desc = action.desc or ("临时操作: " .. name),
			})
			table.insert(bound_keys, { buf = bufnr, key = key })
		end
	end

	-- 3. 自动清理：窗口关闭/缓冲区删除时移除所有临时映射
	vim.api.nvim_create_autocmd({ "WinClosed", "BufDelete", "BufUnload" }, {
		buffer = bufnr,
		once = true,
		callback = function()
			for _, item in ipairs(bound_keys) do
				pcall(vim.keymap.del, "n", item.key, { buffer = item.buf })
			end
		end,
	})

	-- 4. 独立帮助浮窗（仅对 float 模式生效）
	if opts.show_hint and opts.type == "float" and winid then
		local hint = "操作: "
		for name, action in pairs(opts.actions) do
			hint = hint .. string.format("[%s] %s  ", action.key, action.desc or name)
		end
		local win_config = vim.api.nvim_win_get_config(winid)
		local width = win_config.width
		if type(width) == "table" then
			width = width[1]
		end
		local footer_win, footer_buf = create_footer_window(winid, bufnr, width, hint)
	end

	-- 5. 后备：非浮窗模式仍使用 footer 显示提示
	if opts.show_hint and winid and opts.type ~= "float" then
		local hint = "操作: "
		for name, action in pairs(opts.actions) do
			hint = hint .. string.format("[%s] %s  ", action.key, action.desc or name)
		end
		pcall(vim.api.nvim_win_set_config, winid, {
			footer = { { " " .. hint .. " ", "Comment" } },
			footer_pos = "right",
		})
	end

	return bufnr, winid
end

---------------------------------------------------------------------
-- 清理缓存（调试用）
---------------------------------------------------------------------
function M.clear_cache()
	_window_cache = {}
	_file_content_cache.data = {}
end

return M
