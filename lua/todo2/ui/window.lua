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
	max_size = 5, -- 缓存最近5个文件的内容
	data = {},
}

---------------------------------------------------------------------
-- 获取缓存的文件内容
---------------------------------------------------------------------
local function get_cached_file_content(path)
	if _file_content_cache.data[path] then
		return _file_content_cache.data[path]
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil
	end

	-- 添加新缓存，清理旧缓存
	local keys = vim.tbl_keys(_file_content_cache.data)
	if #keys >= _file_content_cache.max_size then
		_file_content_cache.data[keys[1]] = nil
	end

	_file_content_cache.data[path] = lines
	return lines
end

---------------------------------------------------------------------
-- 内部函数：创建浮动窗口
---------------------------------------------------------------------
local function create_floating_window(bufnr, path, ui_module)
	local core = module.get("core")
	local conceal = module.get("ui.conceal")
	local statistics = module.get("ui.statistics")

	-- 使用缓存获取文件内容
	local lines = get_cached_file_content(path)
	if not lines then
		vim.notify("无法读取文件: " .. path, vim.log.levels.ERROR)
		return
	end

	local width = math.min(math.floor(vim.o.columns * 0.8), 140)
	local height = math.min(30, math.max(10, #lines + 4))
	local col = math.floor((vim.o.columns - width) / 2)
	local row = math.floor((vim.o.lines - height) / 2)

	local win = vim.api.nvim_open_win(bufnr, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		border = "rounded",
		title = "📋 TODO - " .. vim.fn.fnamemodify(path, ":t"),
		style = "minimal",
	})

	conceal.apply_conceal(bufnr)

	-- 缓存窗口信息
	_window_cache[bufnr] = {
		win = win,
		path = path,
		update_summary = nil,
	}

	-- summary 更新函数
	local function update_summary()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end

		local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local filepath = vim.api.nvim_buf_get_name(bufnr)
		local stat = core.summarize(current_lines, filepath)
		local footer_text = statistics.format_summary(stat)

		pcall(vim.api.nvim_win_set_config, win, {
			footer = { { " " .. footer_text .. " ", "Number" } },
			footer_pos = "right",
		})
	end

	_window_cache[bufnr].update_summary = update_summary

	-- 使用新的 keymaps 系统
	local new_keymaps = require("todo2.keymaps")
	local is_float_window = true
	new_keymaps.bind_for_context(bufnr, "markdown", is_float_window)

	-- 使用UI模块的智能刷新
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = bufnr,
		callback = function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end

			-- 立即更新 summary
			update_summary()

			-- 使用智能刷新（区分打字和粘贴）
			local event_type = vim.v.event and vim.v.event.input_type or "typing"
			local mode = (event_type == "paste") and "paste" or "typing"

			if ui_module and ui_module.schedule_refresh then
				ui_module.schedule_refresh(bufnr, { mode = mode, priority = 100 })
			end
		end,
	})

	return win, update_summary
end

---------------------------------------------------------------------
-- 浮动窗口模式
---------------------------------------------------------------------
function M.show_floating(path, line_number, enter_insert, ui_module)
	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)

	-- 设置缓冲区选项
	local buf_opts = {
		buftype = "",
		bufhidden = "wipe",
		modifiable = true,
		readonly = false,
		swapfile = false,
		filetype = "markdown",
	}

	for opt, val in pairs(buf_opts) do
		vim.bo[bufnr][opt] = val
	end

	local win, update_summary = create_floating_window(bufnr, path, ui_module)
	if not win then
		return
	end

	-- 初次刷新
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(bufnr) and ui_module and ui_module.refresh then
			ui_module.refresh(bufnr)
		end
		if update_summary then
			update_summary()
		end

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
-- 分割窗口模式
---------------------------------------------------------------------
function M.show_split(path, line_number, enter_insert, split_direction, ui_module)
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
	}

	for opt, val in pairs(buf_opts) do
		vim.bo[bufnr][opt] = val
	end

	-- 缓存窗口信息
	_window_cache[bufnr] = {
		win = new_win,
		path = path,
	}

	local conceal = module.get("ui.conceal")
	conceal.apply_conceal(bufnr)

	-- 初次刷新
	if vim.api.nvim_buf_is_valid(bufnr) and ui_module and ui_module.refresh then
		ui_module.refresh(bufnr)
	end

	if line_number and vim.api.nvim_win_is_valid(new_win) then
		vim.api.nvim_win_set_cursor(new_win, { line_number, 0 })
		vim.api.nvim_win_call(new_win, function()
			vim.cmd("normal! zz")
		end)
	end

	-- 使用新的 keymaps 系统
	local new_keymaps = require("todo2.keymaps")
	local is_float_window = false
	new_keymaps.bind_for_context(bufnr, "markdown", is_float_window)

	-- 使用UI模块的智能刷新
	if ui_module and ui_module.schedule_refresh then
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
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	local bufnr = vim.api.nvim_get_current_buf()

	local buf_opts = {
		buftype = "",
		modifiable = true,
		readonly = false,
		swapfile = false,
		filetype = "markdown",
	}

	for opt, val in pairs(buf_opts) do
		vim.bo[bufnr][opt] = val
	end

	-- 缓存窗口信息
	_window_cache[bufnr] = {
		win = vim.api.nvim_get_current_win(),
		path = path,
	}

	local conceal = module.get("ui.conceal")
	conceal.apply_conceal(bufnr)

	-- 初次刷新
	if vim.api.nvim_buf_is_valid(bufnr) and ui_module and ui_module.refresh then
		ui_module.refresh(bufnr)
	end

	if line_number then
		vim.fn.cursor(line_number, 1)
		vim.cmd("normal! zz")
	end

	-- 编辑模式下也绑定按键映射
	local new_keymaps = require("todo2.keymaps")
	local is_float_window = false
	new_keymaps.bind_for_context(bufnr, "markdown", is_float_window)

	-- 使用UI模块的智能刷新
	if ui_module and ui_module.schedule_refresh then
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

-- 添加缓存清理函数
function M.clear_cache()
	_window_cache = {}
	_file_content_cache.data = {}
end

return M
