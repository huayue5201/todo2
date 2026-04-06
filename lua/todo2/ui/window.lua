-- lua/todo2/ui/window.lua
-- 极简版：UI 只负责窗口，不绑定任何 keymap

local M = {}

local core = require("todo2.core.stats")
local statistics = require("todo2.ui.statistics")

local _global_float_win = nil

---------------------------------------------------------------------
-- 工具函数：安全路径
---------------------------------------------------------------------
local function safe_path(path)
	if type(path) ~= "string" then
		return nil
	end
	local abs_path = vim.fs.normalize(vim.fn.expand(path, ":p"))
	return abs_path ~= "" and abs_path or nil
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
-- 全局浮窗（复用）
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
				local line_count = vim.api.nvim_buf_line_count(buf)
				line_number = math.max(1, math.min(line_number, line_count))
				pcall(vim.api.nvim_win_set_cursor, _global_float_win, { line_number, 0 })
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
	end
	return bufnr, win
end

---------------------------------------------------------------------
-- 创建浮窗
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
-- summary（不依赖 parser）
---------------------------------------------------------------------
local function build_summary(bufnr, win)
	if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local filepath = vim.api.nvim_buf_get_name(bufnr)

	local stat = core.summarize(lines, filepath)
	local footer_text = statistics and statistics.format_summary(stat) or "暂无统计"

	pcall(vim.api.nvim_win_set_config, win, {
		footer = { { " " .. footer_text .. " ", "Number" } },
		footer_pos = "right",
	})
end

---------------------------------------------------------------------
-- 浮动窗口模式
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

	-- ❗ 不再绑定 keymap（由 keymaps.lua 负责）
	-- ❗ 不再调用 keymaps.bind_for_context（已删除）

	vim.defer_fn(function()
		build_summary(bufnr, win)

		if line_number then
			local line_count = vim.api.nvim_buf_line_count(bufnr)
			line_number = math.max(1, math.min(line_number, line_count))
			pcall(vim.api.nvim_win_set_cursor, win, { line_number, 0 })
		end

		if enter_insert then
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
		end
	end, 30)

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
		buffer = bufnr,
		callback = function()
			if vim.api.nvim_win_is_valid(win) then
				build_summary(bufnr, win)
			end
		end,
	})

	return bufnr, win
end

---------------------------------------------------------------------
-- split 模式
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

	-- ❗ 不再绑定 keymap

	if line_number then
		local line_count = vim.api.nvim_buf_line_count(bufnr)
		line_number = math.max(1, math.min(line_number, line_count))
		pcall(vim.api.nvim_win_set_cursor, win, { line_number, 0 })
	end

	if enter_insert then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	return bufnr, win
end

---------------------------------------------------------------------
-- edit 模式
---------------------------------------------------------------------
function M.show_edit(path, line_number, enter_insert)
	path = safe_path(path)
	if not path then
		return nil
	end

	vim.cmd("edit " .. vim.fn.fnameescape(path))
	local bufnr = vim.api.nvim_get_current_buf()

	-- ❗ 不再绑定 keymap

	if line_number then
		local line_count = vim.api.nvim_buf_line_count(bufnr)
		line_number = math.max(1, math.min(line_number, line_count))
		pcall(vim.fn.cursor, line_number, 1)
	end

	if enter_insert then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	return bufnr
end

---------------------------------------------------------------------
-- open_with_actions（保持原样）
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

	-- 临时按键（保持原功能）
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

	return bufnr, winid
end

return M
