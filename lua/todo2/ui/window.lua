--- File: /Users/lijia/todo2/lua/todo2/ui/window.lua ---
-- lua/todo2/ui/window.lua
--- @module todo2.ui.window
--- @brief 专业版：UI 只负责展示，不负责刷新逻辑（刷新交给事件系统）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 内部函数：创建浮动窗口
---------------------------------------------------------------------
local function create_floating_window(bufnr, path, ui_module)
	-- 通过模块管理器获取依赖
	local core = module.get("core")
	local conceal = module.get("ui.conceal")
	local statistics = module.get("ui.statistics")

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
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

	-----------------------------------------------------------------
	-- summary 更新（UI 层职责）
	-----------------------------------------------------------------
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

	-- ✅ 使用新的 keymaps 系统设置键位
	local new_keymaps = require("todo2.keymaps")
	local is_float_window = true
	new_keymaps.bind_for_context(bufnr, "markdown", is_float_window)

	-----------------------------------------------------------------
	-- 自动命令：文本变化时更新 summary 和刷新渲染
	-----------------------------------------------------------------
	local augroup = vim.api.nvim_create_augroup("TodoFloating_" .. path:gsub("[^%w]", "_"), { clear = true })

	-- 使用防抖避免频繁刷新
	local refresh_timer = nil
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		buffer = bufnr,
		callback = function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end

			-- 立即更新 summary
			update_summary()

			-- 防抖刷新 UI（延迟 150ms）
			if refresh_timer then
				refresh_timer:close()
			end

			refresh_timer = vim.defer_fn(function()
				if ui_module and ui_module.refresh then
					ui_module.refresh(bufnr)
				end
				refresh_timer = nil
			end, 150)
		end,
	})

	-- 窗口关闭时清理定时器
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		buffer = bufnr,
		callback = function()
			if refresh_timer then
				refresh_timer:close()
				refresh_timer = nil
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

	-- 初次刷新（UI 初始化必须 refresh）
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

	-- 通过模块管理器获取 conceal 模块
	local conceal = module.get("ui.conceal")
	conceal.apply_conceal(bufnr)

	-- 初次刷新（UI 初始化必须 refresh）
	if vim.api.nvim_buf_is_valid(bufnr) and ui_module and ui_module.refresh then
		ui_module.refresh(bufnr)
	end

	if line_number and vim.api.nvim_win_is_valid(new_win) then
		vim.api.nvim_win_set_cursor(new_win, { line_number, 0 })
		vim.api.nvim_win_call(new_win, function()
			vim.cmd("normal! zz")
		end)
	end

	-- ✅ 使用新的 keymaps 系统设置键位
	local new_keymaps = require("todo2.keymaps")
	local is_float_window = false
	new_keymaps.bind_for_context(bufnr, "markdown", is_float_window)

	-----------------------------------------------------------------
	-- 自动命令：文本变化时刷新 UI
	-----------------------------------------------------------------
	local augroup = vim.api.nvim_create_augroup("TodoSplit_" .. path:gsub("[^%w]", "_"), { clear = true })

	-- 使用防抖避免频繁刷新
	local refresh_timer = nil
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		buffer = bufnr,
		callback = function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end

			-- 防抖刷新 UI（延迟 150ms）
			if refresh_timer then
				refresh_timer:close()
			end

			refresh_timer = vim.defer_fn(function()
				if ui_module and ui_module.refresh then
					ui_module.refresh(bufnr)
				end
				refresh_timer = nil
			end, 150)
		end,
	})

	-- 窗口关闭时清理定时器
	vim.api.nvim_create_autocmd("BufWinLeave", {
		group = augroup,
		buffer = bufnr,
		callback = function()
			if refresh_timer then
				refresh_timer:close()
				refresh_timer = nil
			end
		end,
	})

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

	-- 通过模块管理器获取 conceal 模块
	local conceal = module.get("ui.conceal")
	conceal.apply_conceal(bufnr)

	-- 初次刷新（UI 初始化必须 refresh）
	if vim.api.nvim_buf_is_valid(bufnr) and ui_module and ui_module.refresh then
		ui_module.refresh(bufnr)
	end

	if line_number then
		vim.fn.cursor(line_number, 1)
		vim.cmd("normal! zz")
	end

	-- ✅ 编辑模式下也绑定按键映射
	local new_keymaps = require("todo2.keymaps")
	local is_float_window = false
	new_keymaps.bind_for_context(bufnr, "markdown", is_float_window)

	if enter_insert then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	return bufnr
end

return M
