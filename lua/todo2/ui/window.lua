-- lua/todo2/ui/window.lua
--- @module todo2.ui.window

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 内部缓存
---------------------------------------------------------------------
local _window_cache = {}
local _file_content_cache = {
	max_size = 5,
	data = {},
}

---------------------------------------------------------------------
-- 工具函数：安全处理路径（核心修复：确保返回字符串）
---------------------------------------------------------------------
local function safe_path(path)
	if type(path) ~= "string" then
		return nil
	end
	-- 强制转义并标准化路径
	local norm_path = vim.fn.fnamemodify(vim.fn.expand(path, ":p"), ":p")
	return norm_path ~= "" and norm_path or nil
end

---------------------------------------------------------------------
-- 获取缓存的文件内容（核心修复：中文路径兼容+字符串校验）
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

	-- 核心修复：使用vim.loop读取文件，兼容中文路径
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
-- 内部函数：创建浮动窗口（增强容错+字符串校验）
---------------------------------------------------------------------
local function create_floating_window(bufnr, path, ui_module)
	-- 前置校验：确保所有参数都是有效字符串/数字
	if type(bufnr) ~= "number" or bufnr < 1 then
		vim.notify("无效的缓冲区ID: " .. tostring(bufnr), vim.log.levels.ERROR)
		return nil
	end

	path = safe_path(path)
	if not path then
		return nil
	end

	local core = module.get("core")
	local conceal = module.get("ui.conceal")
	local statistics = module.get("ui.statistics")

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

	-- 核心修复：正确处理pcall返回值（第一个返回值是是否成功）
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

	conceal.apply_conceal(bufnr)

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
		local stat = core.summarize(current_lines, filepath)
		local footer_text = statistics and statistics.format_summary(stat) or "暂无统计"

		pcall(vim.api.nvim_win_set_config, win, {
			footer = { { " " .. footer_text .. " ", "Number" } },
			footer_pos = "right",
		})
	end

	_window_cache[bufnr].update_summary = update_summary

	-- 延迟加载keymaps，避免依赖缺失
	local ok_keymap, new_keymaps = pcall(require, "todo2.keymaps")
	if ok_keymap then
		new_keymaps.bind_for_context(bufnr, "markdown", true)
	else
		vim.notify("按键映射模块加载失败: " .. tostring(new_keymaps), vim.log.levels.WARN)
	end

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
-- 浮动窗口模式（核心修复：解决字符串错误+参数校验）
---------------------------------------------------------------------
function M.show_floating(path, line_number, enter_insert, ui_module)
	-- 核心修复1：强制校验路径类型
	path = safe_path(path)
	if not path then
		vim.notify("无效的文件路径（非字符串）", vim.log.levels.ERROR)
		return nil, nil
	end

	-- 核心修复2：正确处理pcall返回值（ok, result）
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

	-- 修正：只保留正确的缓冲区本地选项
	local buf_opts = {
		buftype = "",
		bufhidden = "wipe",
		modifiable = true,
		readonly = false,
		swapfile = false,
		filetype = "markdown",
		-- 缓冲区本地编码选项
		fileencoding = "utf-8",
	}

	-- 核心修复3：校验缓冲区有效性后再设置选项，使用pcall保护
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

	-- 核心修复4：校验缓冲区有效后再创建窗口
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

		-- 核心修复5：校验行号类型
		line_number = type(line_number) == "number" and line_number or 1
		if line_number and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_cursor(win, { line_number, 0 })
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! zz")
			end)
			if enter_insert then
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
			end
		end
	end, 50)

	return bufnr, win
end

---------------------------------------------------------------------
-- 分割窗口模式（保留原有逻辑，仅添加参数校验）
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

	-- 修正：只保留正确的缓冲区本地选项
	local buf_opts = {
		buftype = "",
		modifiable = true,
		readonly = false,
		swapfile = false,
		filetype = "markdown",
		fileencoding = "utf-8", -- 正确的缓冲区编码选项
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

	local conceal = module.get("ui.conceal")
	if conceal then
		conceal.apply_conceal(bufnr)
	end

	if vim.api.nvim_buf_is_valid(bufnr) and ui_module and type(ui_module.refresh) == "function" then
		ui_module.refresh(bufnr)
	end

	line_number = type(line_number) == "number" and line_number or 1
	if line_number and vim.api.nvim_win_is_valid(new_win) then
		vim.api.nvim_win_set_cursor(new_win, { line_number, 0 })
		vim.api.nvim_win_call(new_win, function()
			vim.cmd("normal! zz")
		end)
	end

	local ok_keymap, new_keymaps = pcall(require, "todo2.keymaps")
	if ok_keymap then
		new_keymaps.bind_for_context(bufnr, "markdown", false)
	end

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
-- 编辑模式（保留原有逻辑，仅添加参数校验）
---------------------------------------------------------------------
function M.show_edit(path, line_number, enter_insert, ui_module)
	path = safe_path(path)
	if not path then
		vim.notify("无效的文件路径", vim.log.levels.ERROR)
		return nil
	end

	vim.cmd("edit " .. vim.fn.fnameescape(path))
	local bufnr = vim.api.nvim_get_current_buf()

	-- 修正：只保留正确的缓冲区本地选项
	local buf_opts = {
		buftype = "",
		modifiable = true,
		readonly = false,
		swapfile = false,
		filetype = "markdown",
		fileencoding = "utf-8", -- 正确的缓冲区编码选项
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

	local conceal = module.get("ui.conceal")
	if conceal then
		conceal.apply_conceal(bufnr)
	end

	if vim.api.nvim_buf_is_valid(bufnr) and ui_module and type(ui_module.refresh) == "function" then
		ui_module.refresh(bufnr)
	end

	line_number = type(line_number) == "number" and line_number or 1
	if line_number then
		vim.fn.cursor(line_number, 1)
		vim.cmd("normal! zz")
	end

	local ok_keymap, new_keymaps = pcall(require, "todo2.keymaps")
	if ok_keymap then
		new_keymaps.bind_for_context(bufnr, "markdown", false)
	end

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

function M.clear_cache()
	_window_cache = {}
	_file_content_cache.data = {}
end

return M
