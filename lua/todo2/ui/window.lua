-- lua/todo2/ui/window.lua
--- @module todo2.ui.window
--- @brief 负责浮窗 / 分屏 / 编辑模式的 TODO 文件展示，并提供稳定的自动刷新机制
---
--- 设计目标：
--- 1. 避免 TextChanged → refresh → TextChanged 的循环
--- 2. 使用防抖（debounce）机制保证刷新稳定
--- 3. 浮窗、分屏、编辑模式行为一致
--- 4. 渲染无闪烁、光标不跳动

local M = {}

local keymaps = require("todo2.ui.keymaps")

---------------------------------------------------------------------
-- 安全 buffer 检查（核心）
---------------------------------------------------------------------

--- 安全检查 buffer 是否仍然有效、已加载、可访问
--- @param buf integer
--- @return boolean
local function safe_buf(buf)
	if type(buf) ~= "number" then
		return false
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	if not vim.api.nvim_buf_is_loaded(buf) then
		return false
	end
	-- 最终验证：尝试安全读取名称
	local ok = pcall(vim.api.nvim_buf_get_name, buf)
	return ok
end

---------------------------------------------------------------------
-- 防抖刷新机制（核心）
---------------------------------------------------------------------

--- 全局刷新定时器
local refresh_timer = nil

--- 防抖刷新：避免 TextChanged → refresh → TextChanged 循环
---
--- @param bufnr integer
--- @param ui_module table
local function schedule_refresh(bufnr, ui_module)
	-- 如果已有定时器，先停止
	if refresh_timer then
		refresh_timer:stop()
		refresh_timer:close()
		refresh_timer = nil
	end

	-- 创建新的防抖定时器（延迟 50ms）
	refresh_timer = vim.loop.new_timer()
	refresh_timer:start(50, 0, function()
		vim.schedule(function()
			if safe_buf(bufnr) and ui_module and ui_module.refresh then
				ui_module.refresh(bufnr)
			end
		end)
	end)
end

---------------------------------------------------------------------
-- 内部函数：创建浮动窗口
---------------------------------------------------------------------

local function create_floating_window(bufnr, path, ui_module)
	local core = require("todo2.core")
	local conceal = require("todo2.ui.conceal")
	local statistics = require("todo2.ui.statistics")

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		vim.notify("无法读取文件: " .. path, vim.log.levels.ERROR)
		return
	end

	local width = math.min(math.floor(vim.o.columns * 0.6), 140)
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
	-- 安全更新 summary（避免无效 buffer 报错）
	-----------------------------------------------------------------
	local function update_summary()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		if not safe_buf(bufnr) then
			return
		end

		local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local stat = core.summarize(current_lines)
		local footer_text = statistics.format_summary(stat)

		pcall(vim.api.nvim_win_set_config, win, {
			footer = { { " " .. footer_text .. " ", "Number" } },
			footer_pos = "right",
		})
	end

	-- 设置键位
	keymaps.setup_keymaps(bufnr, win, ui_module)

	-----------------------------------------------------------------
	-- 自动刷新（使用防抖机制 + buffer 安全检查）
	-----------------------------------------------------------------

	local augroup = vim.api.nvim_create_augroup("TodoFloating_" .. path:gsub("[^%w]", "_"), { clear = true })

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
		group = augroup,
		buffer = bufnr,
		callback = function()
			if vim.api.nvim_win_is_valid(win) and safe_buf(bufnr) then
				schedule_refresh(bufnr, ui_module)
				update_summary()
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

	-- 初次刷新（异步安全）
	vim.defer_fn(function()
		if safe_buf(bufnr) and ui_module and ui_module.refresh then
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
	-- 保存当前窗口
	local current_win = vim.api.nvim_get_current_win()

	-- 创建分屏
	if split_direction == "vertical" or split_direction == "v" then
		vim.cmd("vsplit")
	else
		vim.cmd("split")
	end

	local new_win = vim.api.nvim_get_current_win()
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	local bufnr = vim.api.nvim_get_current_buf()

	-- 设置缓冲区选项
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

	-- conceal
	local conceal = require("todo2.ui.conceal")
	conceal.apply_conceal(bufnr)

	-- 初次刷新
	if safe_buf(bufnr) and ui_module and ui_module.refresh then
		ui_module.refresh(bufnr)
	end

	-- 跳转到指定行
	if line_number and vim.api.nvim_win_is_valid(new_win) then
		vim.api.nvim_win_set_cursor(new_win, { line_number, 0 })
		vim.api.nvim_win_call(new_win, function()
			vim.cmd("normal! zz")
		end)
	end

	-- 设置键位
	keymaps.setup_keymaps(bufnr, new_win, ui_module)

	-----------------------------------------------------------------
	-- 自动刷新（使用防抖机制 + buffer 安全检查）
	-----------------------------------------------------------------

	local augroup = vim.api.nvim_create_augroup("TodoSplit_" .. path:gsub("[^%w]", "_"), { clear = true })

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
		group = augroup,
		buffer = bufnr,
		callback = function()
			if vim.api.nvim_win_is_valid(new_win) and safe_buf(bufnr) then
				schedule_refresh(bufnr, ui_module)
			end
		end,
	})

	-- 进入插入模式
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

	local conceal = require("todo2.ui.conceal")
	conceal.apply_conceal(bufnr)

	if safe_buf(bufnr) and ui_module and ui_module.refresh then
		ui_module.refresh(bufnr)
	end

	if line_number then
		vim.fn.cursor(line_number, 1)
		vim.cmd("normal! zz")
	end

	if enter_insert then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	return bufnr
end

-- ⭐ 导出 safe_buf，供其它模块复用（例如 ui.keymaps）
M.safe_buf = safe_buf

return M
