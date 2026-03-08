-- lua/todo2/link/preview.lua
--- @module todo2.link.preview
--- @brief 预览 TODO 或代码（完整任务树，不受 context_split 影响）
--- @description 支持中文显示优化，使用显示宽度计算窗口大小，修复中文截断问题
--- @version 2.5.1 (使用 scheduler 的文件缓存并保留 safe_read_file 回退)

local M = {}

---------------------------------------------------------------------
-- 直接依赖（只做“数据获取”和“ID解析”，解析缓存交给 scheduler）
---------------------------------------------------------------------
local store_link = require("todo2.store.link")
local id_utils = require("todo2.utils.id")
local scheduler = require("todo2.render.scheduler")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------

local DEFAULT_CONFIG = {
	min_width = 60,
	max_width = 120,
	padding = 8,
	max_height = 30,
	todo_zindex = 100,
	code_zindex = 200,
	border_chars = 2,
	safety_margin = 2,
	wrap_text = true,
	wrap_threshold = 0.9,
}

local current_preview = {
	win = nil,
	buf = nil,
	type = nil,
	win_close_autocmd = nil,
	line_mapping = nil,
	target_line = nil,
	window_width = nil,
}

local cursor_autocmd_id = nil

---------------------------------------------------------------------
-- 显示宽度 / 换行相关
---------------------------------------------------------------------

local function get_display_width(str)
	if not str or str == "" then
		return 0
	end
	local ok, width = pcall(vim.fn.strdisplaywidth, str)
	if ok and width then
		return width
	end
	local len = 0
	local i = 1
	while i <= #str do
		local b = str:byte(i)
		if not b then
			break
		end
		if b < 128 then
			len = len + 1
			i = i + 1
		elseif b >= 192 and b <= 223 then
			len = len + 2
			i = i + 2
		elseif b >= 224 and b <= 239 then
			len = len + 2
			i = i + 3
		elseif b >= 240 and b <= 247 then
			len = len + 2
			i = i + 4
		else
			i = i + 1
		end
	end
	return len
end

local function get_max_line_width(lines)
	local max_width = 0
	for _, line in ipairs(lines) do
		local width = get_display_width(line)
		if width > max_width then
			max_width = width
		end
	end
	return max_width
end

local function should_wrap_lines(lines, window_width, threshold)
	if not DEFAULT_CONFIG.wrap_text then
		return false
	end
	local max_content_width = get_max_line_width(lines)
	local content_width = max_content_width + DEFAULT_CONFIG.border_chars + DEFAULT_CONFIG.safety_margin
	return content_width > window_width * threshold
end

local function wrap_text_content(text, max_width)
	if not text or text == "" then
		return { "" }
	end

	max_width = math.max(1, max_width)

	local lines = {}
	local current_line = ""
	local current_width = 0

	local i = 1
	while i <= #text do
		local char = text:sub(i, i)
		local b = char:byte()
		local char_width = 1
		local char_len = 1

		if b and b >= 192 then
			if b >= 192 and b <= 223 then
				char_len = 2
			elseif b >= 224 and b <= 239 then
				char_len = 3
			elseif b >= 240 and b <= 247 then
				char_len = 4
			end

			if i + char_len - 1 <= #text then
				char = text:sub(i, i + char_len - 1)
				char_width = 2
				i = i + char_len
			else
				i = i + 1
				goto continue
			end
		else
			i = i + 1
		end

		if current_width + char_width > max_width then
			table.insert(lines, current_line)
			current_line = char
			current_width = char_width
		else
			current_line = current_line .. char
			current_width = current_width + char_width
		end

		::continue::
	end

	if current_line ~= "" then
		table.insert(lines, current_line)
	end

	if #lines == 0 then
		lines = { "" }
	end

	return lines
end

local function prepare_preview_content(original_lines, window_width)
	local processed_lines = {}
	local line_mapping = {}
	local current_line_num = 1
	local did_wrap = false

	local need_wrap = should_wrap_lines(original_lines, window_width, DEFAULT_CONFIG.wrap_threshold)

	if not need_wrap then
		for i, line in ipairs(original_lines) do
			table.insert(processed_lines, line)
			line_mapping[i] = {
				original_line = i,
				start_line = current_line_num,
				end_line = current_line_num,
			}
			current_line_num = current_line_num + 1
		end
		return processed_lines, line_mapping, false
	end

	local available_width = window_width - DEFAULT_CONFIG.border_chars - DEFAULT_CONFIG.safety_margin

	for i, line in ipairs(original_lines) do
		local wrapped_lines = wrap_text_content(line, available_width)
		if #wrapped_lines > 1 then
			did_wrap = true
		end

		line_mapping[i] = {
			original_line = i,
			start_line = current_line_num,
			end_line = current_line_num + #wrapped_lines - 1,
		}

		for _, wl in ipairs(wrapped_lines) do
			table.insert(processed_lines, wl)
		end

		current_line_num = current_line_num + #wrapped_lines
	end

	return processed_lines, line_mapping, did_wrap
end

local function get_preview_line_range(line_mapping, original_line)
	if not line_mapping or not original_line then
		return nil, nil
	end
	local mapping = line_mapping[original_line]
	if not mapping then
		return nil, nil
	end
	return mapping.start_line, mapping.end_line
end

---------------------------------------------------------------------
-- 安全读文件（保留为回退方案；优先使用 scheduler.get_file_lines）
---------------------------------------------------------------------

local function safe_read_file(path)
	local stat = vim.loop.fs_stat(path)
	if not stat then
		return false, "文件不存在: " .. path
	end

	if stat.size > 1024 * 1024 then
		return false, "文件过大，跳过预览: " .. path
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if ok then
		return true, lines
	end

	local fd = vim.loop.fs_open(path, "r", 438)
	if not fd then
		return false, "无法打开文件: " .. path
	end

	local st = vim.loop.fs_fstat(fd)
	local data = vim.loop.fs_read(fd, st.size, 0)
	vim.loop.fs_close(fd)

	if not data then
		return false, "无法读取文件内容: " .. path
	end

	local is_utf8 = true
	for i = 1, math.min(100, #data) do
		local byte = data:byte(i)
		if byte and byte >= 0x80 then
			if byte >= 0xC0 and byte <= 0xDF then
				if not data:byte(i + 1) or data:byte(i + 1) < 0x80 or data:byte(i + 1) > 0xBF then
					is_utf8 = false
					break
				end
				i = i + 1
			elseif byte >= 0xE0 and byte <= 0xEF then
				if not data:byte(i + 1) or not data:byte(i + 2) then
					is_utf8 = false
					break
				end
				i = i + 2
			elseif byte >= 0xF0 and byte <= 0xF7 then
				if not data:byte(i + 1) or not data:byte(i + 2) or not data:byte(i + 3) then
					is_utf8 = false
					break
				end
				i = i + 3
			else
				is_utf8 = false
				break
			end
		end
	end

	if not is_utf8 then
		return false, "文件编码不是 UTF-8，建议转换后重试"
	end

	local lines2 = {}
	for line in data:gmatch("[^\r\n]+") do
		table.insert(lines2, line)
	end

	return true, lines2
end

---------------------------------------------------------------------
-- 任务树遍历（只负责“从根收集所有任务”）
---------------------------------------------------------------------

local function collect_tasks_iterative(root)
	local all = {}
	local stack = { root }
	local visited = {}

	while #stack > 0 do
		local current = table.remove(stack)
		if visited[current] then
			goto continue
		end
		visited[current] = true

		table.insert(all, current)

		if current.children and #current.children > 0 then
			for i = #current.children, 1, -1 do
				table.insert(stack, current.children[i])
			end
		end

		::continue::
	end

	return all
end

---------------------------------------------------------------------
-- 窗口位置 / 高亮 / 关闭逻辑
---------------------------------------------------------------------

local function calculate_window_position(width, height)
	local win_width = vim.api.nvim_get_option("columns")
	local win_height = vim.api.nvim_get_option("lines")
	local cursor_screen_row = vim.fn.winline()
	local cursor_screen_col = vim.fn.wincol()

	local row = 1
	local col = 2

	if cursor_screen_col + width > win_width - 5 then
		col = -width + 2
	end

	if cursor_screen_row + height > win_height - 2 then
		row = -height - 1
	end

	if cursor_screen_col + col < 2 then
		col = 2 - cursor_screen_col
	end

	return row, col
end

local function close_preview_window()
	if current_preview.win and vim.api.nvim_win_is_valid(current_preview.win) then
		pcall(vim.api.nvim_win_close, current_preview.win, true)
	end

	if current_preview.win_close_autocmd then
		pcall(vim.api.nvim_del_autocmd, current_preview.win_close_autocmd)
	end

	current_preview.win = nil
	current_preview.buf = nil
	current_preview.type = nil
	current_preview.win_close_autocmd = nil
	current_preview.line_mapping = nil
	current_preview.target_line = nil
	current_preview.window_width = nil

	if cursor_autocmd_id then
		pcall(vim.api.nvim_del_autocmd, cursor_autocmd_id)
		cursor_autocmd_id = nil
	end
end

local function setup_win_close_listener(win, bufnr)
	if current_preview.win_close_autocmd then
		pcall(vim.api.nvim_del_autocmd, current_preview.win_close_autocmd)
	end

	current_preview.win_close_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
		buffer = bufnr,
		callback = function()
			if current_preview.win == win then
				current_preview.win = nil
				current_preview.buf = nil
				current_preview.type = nil
				current_preview.win_close_autocmd = nil
				current_preview.line_mapping = nil
				current_preview.target_line = nil
				current_preview.window_width = nil
			end
			if cursor_autocmd_id then
				pcall(vim.api.nvim_del_autocmd, cursor_autocmd_id)
				cursor_autocmd_id = nil
			end
		end,
	})
end

local function setup_cursor_listener()
	if cursor_autocmd_id then
		pcall(vim.api.nvim_del_autocmd, cursor_autocmd_id)
	end

	cursor_autocmd_id = vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		callback = function()
			close_preview_window()
		end,
	})
end

local function ensure_highlight_groups()
	local groups = {
		Underlined = { gui = "underline" },
		Search = { guibg = "#3a3a3a" },
		Bold = { gui = "bold" },
		DiffText = { guibg = "#4a4a4a" },
	}

	for group_name, attrs in pairs(groups) do
		local ok = pcall(vim.api.nvim_get_hl_by_name, group_name, false)
		if not ok then
			local cmd = "highlight default " .. group_name
			for k, v in pairs(attrs) do
				cmd = cmd .. " " .. k .. "=" .. v
			end
			pcall(vim.cmd, cmd)
		end
	end

	vim.cmd([[
        highlight default TodoPreviewHighlight guibg=#3a3a3a guifg=NONE gui=underline,bold
        highlight default CodePreviewHighlight guibg=#2a4a2a guifg=NONE gui=underline,bold
        highlight default TodoPreviewLeftMarker guibg=#ffaa00 guifg=#000000
    ]])
end

local function highlight_key_line(bufnr, line_num, highlight_group, line_mapping, original_line)
	highlight_group = highlight_group or "TodoPreviewHighlight"
	ensure_highlight_groups()

	local ns_id = vim.api.nvim_create_namespace("todo_preview_highlight")

	local start_line, end_line
	if line_mapping and original_line then
		start_line, end_line = get_preview_line_range(line_mapping, original_line)
	end
	if not start_line or not end_line then
		start_line = line_num
		end_line = line_num
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, start_line - 1, end_line)

	for line = start_line, end_line do
		local highlights = { "Underlined", "Search", "Bold", "DiffText", highlight_group }
		for _, hl in ipairs(highlights) do
			pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl, line - 1, 0, -1)
		end
		if line == start_line then
			pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, "TodoPreviewLeftMarker", line - 1, 0, 1)
		end
	end
end

---------------------------------------------------------------------
-- 文件类型 / 文件名
---------------------------------------------------------------------

local function get_filetype(path)
	local ft = vim.filetype.match({ filename = path })
	if not ft then
		-- 优先使用 scheduler 的文件行缓存读取前几行判断 filetype，避免创建临时 buf
		local lines = scheduler.get_file_lines(path, false)
		if lines and #lines > 0 then
			local sample = {}
			for i = 1, math.min(5, #lines) do
				table.insert(sample, lines[i])
			end
			-- 尝试用 sample 判断
			local ok, detected = pcall(function()
				local bufnr = vim.api.nvim_create_buf(false, true)
				if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
					pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, sample)
					local r = vim.filetype.match({ buf = bufnr })
					pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
					return r
				end
				return nil
			end)
			if ok and detected then
				ft = detected
			end
		end
	end
	return ft or "text"
end

local function get_filename(path)
	local name = path:match("([^/\\]+)$")
	if name then
		name = name:gsub("^[A-Za-z]:", "")
		return name
	end
	return path
end

---------------------------------------------------------------------
-- 创建预览窗口（核心）
---------------------------------------------------------------------

local function create_preview_window(lines, title, filetype, zindex, target_line_num, highlight_group)
	local max_content_width = get_max_line_width(lines)
	local border_width = DEFAULT_CONFIG.border_chars
	local min_width = DEFAULT_CONFIG.min_width
	local max_width = DEFAULT_CONFIG.max_width
	local margin = DEFAULT_CONFIG.safety_margin

	local content_chars = math.ceil(max_content_width)
	if content_chars % 2 == 1 then
		content_chars = content_chars + 1
	end

	local initial_width = content_chars + border_width + margin
	initial_width = math.max(initial_width, min_width)
	initial_width = math.min(initial_width, max_width)
	initial_width = math.floor(initial_width)

	local processed_lines, line_mapping, did_wrap = prepare_preview_content(lines, initial_width)

	local final_width = initial_width
	if did_wrap then
		local new_max_width = get_max_line_width(processed_lines)
		local new_content_chars = math.ceil(new_max_width)
		if new_content_chars % 2 == 1 then
			new_content_chars = new_content_chars + 1
		end
		final_width = new_content_chars + border_width + margin
		final_width = math.max(final_width, min_width)
		final_width = math.min(final_width, max_width)
		final_width = math.floor(final_width)
	end

	local height = math.min(#processed_lines, DEFAULT_CONFIG.max_height)
	local row, col = calculate_window_position(final_width, height)

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, processed_lines)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(bufnr, "filetype", filetype)
	vim.api.nvim_buf_set_option(bufnr, "swapfile", false)

	local win = vim.api.nvim_open_win(bufnr, false, {
		relative = "cursor",
		width = final_width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
		focusable = true,
		zindex = zindex,
	})

	vim.api.nvim_win_set_option(win, "wrap", did_wrap)
	vim.api.nvim_win_set_option(win, "linebreak", did_wrap)
	vim.api.nvim_win_set_option(win, "number", false)
	vim.api.nvim_win_set_option(win, "relativenumber", false)
	vim.api.nvim_win_set_option(win, "cursorline", false)

	current_preview.win = win
	current_preview.buf = bufnr
	current_preview.type = filetype == "markdown" and "todo" or "code"
	current_preview.line_mapping = line_mapping
	current_preview.target_line = target_line_num
	current_preview.window_width = final_width

	highlight_key_line(bufnr, target_line_num, highlight_group, line_mapping, target_line_num)
	setup_win_close_listener(win, bufnr)
	setup_cursor_listener()

	return true
end

---------------------------------------------------------------------
-- 预览 TODO：只负责“拿到任务树 + 构造展示片段”
-- 解析树来源统一走 scheduler.get_parse_tree（共享缓存）
-- 读取文件优先使用 scheduler.get_file_lines，失败时回退到 safe_read_file
---------------------------------------------------------------------

function M.preview_todo()
	close_preview_window()

	local line = vim.fn.getline(".")
	if not id_utils.contains_code_mark(line) then
		return
	end

	local tag = id_utils.extract_tag_from_code_mark(line)
	if not tag then
		-- tag 实际上这里不用，但保持行为一致
	end

	local id = id_utils.extract_id_from_code_mark(line)
	if not id then
		return
	end

	if not store_link then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

	local link = store_link.get_todo(id, { verify_line = true })
	if not link then
		vim.notify("未找到对应的 TODO 链接，ID: " .. id, vim.log.levels.WARN)
		return
	end

	local todo_path = link.path

	-- 优先使用 scheduler 的文件缓存
	local lines = scheduler.get_file_lines(todo_path, false)
	if not lines or #lines == 0 then
		local ok2, lines2 = safe_read_file(todo_path)
		if not ok2 then
			vim.notify("无法读取文件: " .. todo_path .. " - " .. lines2, vim.log.levels.ERROR)
			return
		end
		lines = lines2
	end

	-- 解析树统一从 scheduler 获取，避免重复解析 / 重复缓存
	local _, _, id_to_task = scheduler.get_parse_tree(todo_path, false)
	local current = id_to_task and id_to_task[id]
	if not current then
		vim.notify("任务树中未找到 ID 为 " .. id .. " 的任务", vim.log.levels.WARN)
		return
	end

	local root = current
	while root.parent do
		root = root.parent
	end

	local all = collect_tasks_iterative(root)

	local min_line = math.huge
	local max_line = -1
	for _, t in ipairs(all) do
		if t.line_num then
			if t.line_num < min_line then
				min_line = t.line_num
			end
			if t.line_num > max_line then
				max_line = t.line_num
			end
		end
	end

	if min_line == math.huge or max_line == -1 then
		vim.notify("无法确定任务行范围", vim.log.levels.WARN)
		return
	end

	local preview_lines = {}
	for i = min_line, max_line do
		preview_lines[#preview_lines + 1] = lines[i] or ""
	end

	local filename = get_filename(todo_path)
	local title = " " .. filename .. " "
	local target_line = current.line_num - min_line + 1

	create_preview_window(
		preview_lines,
		title,
		"markdown",
		DEFAULT_CONFIG.todo_zindex,
		target_line,
		"TodoPreviewHighlight"
	)
end

---------------------------------------------------------------------
-- 预览代码：只做“锚点 → 代码上下文片段”
-- 读取文件优先使用 scheduler.get_file_lines，失败时回退到 safe_read_file
---------------------------------------------------------------------

function M.preview_code()
	close_preview_window()

	local line = vim.fn.getline(".")
	if not id_utils.contains_todo_anchor(line) then
		return
	end

	local id = id_utils.extract_id_from_todo_anchor(line)
	if not id then
		return
	end

	if not store_link then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

	local link = store_link.get_code(id, { verify_line = true })
	if not link then
		vim.notify("未找到对应的代码锚点，ID: " .. id, vim.log.levels.WARN)
		return
	end

	local lines = scheduler.get_file_lines(link.path, false)
	if not lines or #lines == 0 then
		local ok2, lines2 = safe_read_file(link.path)
		if not ok2 then
			vim.notify("无法读取文件: " .. link.path .. " - " .. lines2, vim.log.levels.ERROR)
			return
		end
		lines = lines2
	end

	local start_line = math.max(1, link.line - 3)
	local end_line = math.min(#lines, link.line + 3)
	local context_lines = {}

	for i = start_line, end_line do
		context_lines[#context_lines + 1] = lines[i]
	end

	local filetype = get_filetype(link.path)
	local filename = get_filename(link.path)
	local title = " " .. filename .. " "
	local target_line = link.line - start_line + 1

	create_preview_window(
		context_lines,
		title,
		filetype,
		DEFAULT_CONFIG.code_zindex,
		target_line,
		"CodePreviewHighlight"
	)
end

---------------------------------------------------------------------
-- 手动关闭
---------------------------------------------------------------------

function M.close_preview()
	close_preview_window()
end

---------------------------------------------------------------------
-- setup：只负责合并配置 + 高亮初始化
---------------------------------------------------------------------

function M.setup(config)
	if config then
		for k, v in pairs(config) do
			if DEFAULT_CONFIG[k] ~= nil then
				DEFAULT_CONFIG[k] = v
			end
		end
	end
	ensure_highlight_groups()
end

return M
