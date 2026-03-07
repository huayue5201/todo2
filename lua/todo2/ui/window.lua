-- lua/todo2/ui/window.lua
-- @module todo2.ui.window
-- 最终修复版：UI 完整，完全移除渲染逻辑（refresh/schedule_refresh/parser/conceal）

local M = {}

---------------------------------------------------------------------
-- 依赖（仅 UI 所需）
---------------------------------------------------------------------
local core = require("todo2.core.stats")
local statistics = require("todo2.ui.statistics")
local keymaps = require("todo2.keymaps")

---------------------------------------------------------------------
-- 内部缓存
---------------------------------------------------------------------
local _window_cache = {}
local _global_float_win = nil
local _global_float_buf = nil

---------------------------------------------------------------------
-- 工具函数：安全路径
---------------------------------------------------------------------
local function safe_path(path)
	if type(path) ~= "string" then
		return nil
	end
	local norm = vim.fn.fnamemodify(vim.fn.expand(path, ":p"), ":p")
	return norm ~= "" and norm or nil
end

---------------------------------------------------------------------
-- 估算文件行数（用于浮窗高度）
---------------------------------------------------------------------
local function get_file_line_count(path)
	path = safe_path(path)
	if not path then
		return 10
	end
	local stat = vim.loop.fs_stat(path)
	if not stat then
		return 10
	end
	local est = math.floor(stat.size / 80) + 4
	return math.max(10, math.min(30, est))
end

---------------------------------------------------------------------
-- 查找已存在的浮窗
---------------------------------------------------------------------
function M.find_existing_float(path)
	path = safe_path(path)
	if not path then
		return nil
	end

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		local buf_path = safe_path(vim.api.nvim_buf_get_name(buf))
		if buf_path == path then
			local cfg = vim.api.nvim_win_get_config(win)
			if cfg.relative ~= "" then
				return win
			end
		end
	end
	return nil
end

---------------------------------------------------------------------
-- 全局浮窗（不触发渲染）
---------------------------------------------------------------------
function M.find_or_create_global_float(path, line_number, enter_insert)
	path = safe_path(path)
	if not path then
		return nil, nil
	end

	if _global_float_win and vim.api.nvim_win_is_valid(_global_float_win) then
		local buf = vim.api.nvim_win_get_buf(_global_float_win)
		local cfg = vim.api.nvim_win_get_config(_global_float_win)

		if cfg.relative ~= "" then
			vim.cmd("edit " .. vim.fn.fnameescape(path))

			vim.api.nvim_win_set_config(_global_float_win, {
				title = "📋 TODO - " .. vim.fn.fnamemodify(path, ":t"),
			})

			vim.api.nvim_set_current_win(_global_float_win)

			if line_number then
				vim.api.nvim_win_set_cursor(_global_float_win, { line_number, 0 })
			end

			if enter_insert then
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
			end

			return buf, _global_float_win
		end
	end

	local bufnr, win = M.show_floating(path, line_number, enter_insert)
	if win then
		_global_float_win = win
		_global_float_buf = bufnr
	end
	return bufnr, win
end

---------------------------------------------------------------------
-- 创建浮窗（不触发渲染）
---------------------------------------------------------------------
local function create_floating_window(bufnr, path)
	local est = get_file_line_count(path)

	local width = math.min(math.floor(vim.o.columns * 0.8), 140)
	local height = math.min(30, math.max(10, est))
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
		return nil
	end

	return win
end

---------------------------------------------------------------------
-- summary（不依赖 parser.parse_file）
---------------------------------------------------------------------
local function build_summary(bufnr, win)
	if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local filepath = vim.api.nvim_buf_get_name(bufnr)

	-- ⭐ 不再调用 parser.parse_file（渲染前置）
	local stat = core.summarize(lines, filepath)
	local footer_text = statistics and statistics.format_summary(stat) or "暂无统计"

	pcall(vim.api.nvim_win_set_config, win, {
		footer = { { " " .. footer_text .. " ", "Number" } },
		footer_pos = "right",
	})
end

---------------------------------------------------------------------
-- 帮助浮窗
---------------------------------------------------------------------
local function create_footer_window(main_win, main_buf, width, hint)
	local cfg = vim.api.nvim_win_get_config(main_win)

	local function get(v)
		return type(v) == "table" and v[1] or v
	end

	local row = get(cfg.row)
	local col = get(cfg.col)
	local height = get(cfg.height)

	local new_row = row + height + 2

	local footer_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = footer_buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = footer_buf })
	vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, { hint })

	local ns = vim.api.nvim_create_namespace("todo2_creation_hint")
	vim.api.nvim_buf_set_extmark(footer_buf, ns, 0, 0, {
		hl_group = "Todo2CreationHint",
		end_col = #hint,
		hl_eol = true,
	})

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
		zindex = cfg.zindex + 1,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		buffer = main_buf,
		once = true,
		callback = function()
			pcall(vim.api.nvim_win_close, footer_win, true)
		end,
	})

	return footer_win, footer_buf
end

---------------------------------------------------------------------
-- 浮动窗口模式（无渲染）
---------------------------------------------------------------------
function M.show_floating(path, line_number, enter_insert)
	path = safe_path(path)
	if not path then
		return nil, nil
	end

	local bufnr = vim.fn.bufnr(path)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(path)
		vim.fn.bufload(bufnr)
	end

	local win = create_floating_window(bufnr, path)
	if not win then
		return nil, nil
	end

	keymaps.bind_for_context(bufnr, "markdown", true)

	vim.defer_fn(function()
		build_summary(bufnr, win)

		if line_number then
			vim.api.nvim_win_set_cursor(win, { line_number, 0 })
		end

		if enter_insert then
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
		end
	end, 30)

	return bufnr, win
end

---------------------------------------------------------------------
-- split 模式（无渲染）
---------------------------------------------------------------------
function M.show_split(path, line_number, enter_insert)
	path = safe_path(path)
	if not path then
		return nil, nil
	end

	vim.cmd("split")
	vim.cmd("edit " .. vim.fn.fnameescape(path))

	local win = vim.api.nvim_get_current_win()
	local bufnr = vim.api.nvim_get_current_buf()

	keymaps.bind_for_context(bufnr, "markdown", false)

	if line_number then
		vim.api.nvim_win_set_cursor(win, { line_number, 0 })
	end

	if enter_insert then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	return bufnr, win
end

---------------------------------------------------------------------
-- edit 模式（无渲染）
---------------------------------------------------------------------
function M.show_edit(path, line_number, enter_insert)
	path = safe_path(path)
	if not path then
		return nil
	end

	vim.cmd("edit " .. vim.fn.fnameescape(path))
	local bufnr = vim.api.nvim_get_current_buf()

	keymaps.bind_for_context(bufnr, "markdown", false)

	if line_number then
		vim.fn.cursor(line_number, 1)
	end

	if enter_insert then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	return bufnr
end

---------------------------------------------------------------------
-- open_with_actions（完整保留）
---------------------------------------------------------------------
function M.open_with_actions(path, opts)
	opts = opts or {}
	local bufnr, winid

	if opts.type == "float" then
		bufnr, winid = M.show_floating(path, opts.line, opts.enter_insert)
	elseif opts.type == "split" then
		bufnr, winid = M.show_split(path, opts.line, opts.enter_insert)
	else
		bufnr = M.show_edit(path, opts.line, opts.enter_insert)
		winid = vim.fn.bufwinid(bufnr)
	end

	if not bufnr or not winid then
		return nil, nil
	end

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

	vim.api.nvim_create_autocmd({ "WinClosed", "BufDelete", "BufUnload" }, {
		buffer = bufnr,
		once = true,
		callback = function()
			for _, item in ipairs(bound_keys) do
				pcall(vim.keymap.del, "n", item.key, { buffer = item.buf })
			end
		end,
	})

	if opts.show_hint and opts.type == "float" and winid then
		local hint = "操作: "
		for name, action in pairs(opts.actions) do
			hint = hint .. string.format("[%s] %s  ", action.key, action.desc or name)
		end
		local cfg = vim.api.nvim_win_get_config(winid)
		local width = type(cfg.width) == "table" and cfg.width[1] or cfg.width
		create_footer_window(winid, bufnr, width, hint)
	end

	return bufnr, winid
end

return M
