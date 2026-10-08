-- lua/todo2/task/preview.lua
-- 预览模块：使用存储中的位置信息

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local core = require("todo2.store.task.core")
local file = require("todo2.utils.file")
local cursor = require("todo2.task.cursor")
local constants = require("todo2.constants")
local config = require("todo2.config")

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
	-- 同一代码锚点横跨多个 root 任务树时，最多并排展示多少棵树
	max_trees = 2,
	-- 多棵树时，每个窗口最多展示多少行任务（超出以锚点行为中心裁剪）
	max_tree_lines = 20,
	-- 并排窗口之间的间隔
	tree_gap = 2,
}

-- 当前打开的所有预览浮窗（同一代码锚点可能横跨多个 root 任务树，需要多个窗口）
local active_previews = {}

local cursor_autocmd_id = nil

--- 获取解析树（复用 scheduler，buffer 优先）
---@param path string
---@return table[], table<string, table>
local function get_parse_tree(path)
	local scheduler = require("todo2.render.scheduler")
	local _, roots, id_to_task = scheduler.get_parse_tree(path)
	return roots, id_to_task or {}
end

---------------------------------------------------------------------
-- 显示宽度 / 换行相关
---------------------------------------------------------------------

local function get_display_width(str)
	if not str or str == "" then
		return 0
	end
	return vim.fn.strdisplaywidth(str)
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
-- 安全读文件
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
	if ok and lines then
		return true, lines
	end
	return false, "无法读取文件: " .. path
end

---------------------------------------------------------------------
-- 任务树遍历
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
	-- 先取出快照并清空全局列表，避免关闭窗口时触发的 WinClosed 回调修改正在遍历的表。
	local previews = active_previews
	active_previews = {}

	for _, p in ipairs(previews) do
		if p.win_close_autocmd then
			pcall(vim.api.nvim_del_autocmd, p.win_close_autocmd)
			p.win_close_autocmd = nil
		end
		if p.win and vim.api.nvim_win_is_valid(p.win) then
			pcall(vim.api.nvim_win_close, p.win, true)
		end
	end

	if cursor_autocmd_id then
		pcall(vim.api.nvim_del_autocmd, cursor_autocmd_id)
		cursor_autocmd_id = nil
	end
end

local function setup_win_close_listener(preview)
	local win = preview.win

	preview.win_close_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			for i, p in ipairs(active_previews) do
				if p == preview then
					table.remove(active_previews, i)
					break
				end
			end
			preview.win_close_autocmd = nil
			if #active_previews == 0 and cursor_autocmd_id then
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

	local ns_id = constants.ns("preview_highlight")

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
		-- 注意：nvim_buf_add_highlight 的 end_col 传 -1 会生成跨到下一行行首的
		-- extmark（end_row=line, end_col=0），导致高亮多行时后一行的清空操作会
		-- 把前一行的整行高亮一并清掉。这里显式用本行长度作为 end_col。
		local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
		local len = math.max(#text, 1)
		local highlights = { "Underlined", "Search", "Bold", "DiffText", highlight_group }
		for _, hl in ipairs(highlights) do
			pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl, line - 1, 0, len)
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
		local lines = file.read_lines_smart(path)
		if lines and #lines > 0 then
			local sample = {}
			for i = 1, math.min(5, #lines) do
				table.insert(sample, lines[i])
			end
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

---------------------------------------------------------------------
-- 创建预览窗口
---------------------------------------------------------------------
--- 计算预览内容与窗口尺寸（不创建窗口），供多窗口排版复用。
--- @param lines string[]
--- @return table { processed_lines, line_mapping, did_wrap, width, height }
local function measure_preview(lines, min_width_override)
	local max_content_width = get_max_line_width(lines)
	local border_width = DEFAULT_CONFIG.border_chars
	local min_width = min_width_override or DEFAULT_CONFIG.min_width
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
	return {
		processed_lines = processed_lines,
		line_mapping = line_mapping,
		did_wrap = did_wrap,
		width = final_width,
		height = height,
	}
end

--- 创建预览窗口。
--- @param pos table|nil { relative, row, col }；为空则相对光标定位
--- @param measured table|nil measure_preview 的结果（多窗口排版时预计算）
--- @return table preview 记录
local function create_preview_window(lines, title, filetype, zindex, target_line_num, highlight_group, pos, measured)
	measured = measured or measure_preview(lines)
	local processed_lines = measured.processed_lines
	local line_mapping = measured.line_mapping
	local did_wrap = measured.did_wrap
	local final_width = measured.width
	local height = measured.height

	local relative = "cursor"
	local row, col
	if pos then
		relative = pos.relative or "cursor"
		row = pos.row or 1
		col = pos.col or 1
	else
		row, col = calculate_window_position(final_width, height)
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, processed_lines)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(bufnr, "filetype", filetype)
	vim.api.nvim_buf_set_option(bufnr, "swapfile", false)

	local win = vim.api.nvim_open_win(bufnr, false, {
		relative = relative,
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

	vim.api.nvim_set_option_value("wrap", did_wrap, { scope = "local", win = win })
	vim.api.nvim_set_option_value("linebreak", did_wrap, { scope = "local", win = win })
	vim.api.nvim_set_option_value("number", false, { scope = "local", win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { scope = "local", win = win })
	vim.api.nvim_set_option_value("cursorline", false, { scope = "local", win = win })

	local target_lines = type(target_line_num) == "table" and target_line_num or { target_line_num }
	if #target_lines == 0 then
		target_lines = { 1 }
	end

	local preview = {
		win = win,
		buf = bufnr,
		type = filetype == "markdown" and "todo" or "code",
		line_mapping = line_mapping,
		target_line = target_lines[1],
		window_width = final_width,
	}
	active_previews[#active_previews + 1] = preview

	for _, tl in ipairs(target_lines) do
		highlight_key_line(bufnr, tl, highlight_group, line_mapping, tl)
	end

	-- markdown（TODO）预览复用 todo2 渲染管线：复选框、状态色、进度、标签、删除线、折叠。
	if filetype == "markdown" then
		pcall(function()
			require("todo2.render.todo_render").render(bufnr)
			require("todo2.render.conceal").apply_buffer_conceal(bufnr)
		end)
	end

	setup_win_close_listener(preview)
	setup_cursor_listener()

	return preview
end

---------------------------------------------------------------------
-- 预览 TODO
---------------------------------------------------------------------

--- 读取预览文件内容（buffer/磁盘优先，safe_read_file 兜底）
--- @param path string
--- @return string[]|nil lines, string|nil err
local function read_file_for_preview(path)
	local lines = file.read_lines_smart(path)
	if lines and #lines > 0 then
		return lines, nil
	end
	local ok, result = safe_read_file(path)
	if not ok then
		return nil, result
	end
	return result, nil
end

function M.preview_todo()
	close_preview_window()

	local id = cursor.get_id()
	if not id then
		return
	end

	local task = core.get_task(id)
	if not task or not task.locations.todo then
		vim.notify("未找到对应的 TODO 任务，ID: " .. id, vim.log.levels.WARN)
		return
	end

	local todo_path = task.locations.todo.path

	local lines, err = read_file_for_preview(todo_path)
	if not lines then
		vim.notify("无法读取文件: " .. todo_path .. " - " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	local roots, id_to_task = get_parse_tree(todo_path)
	local current = id_to_task and id_to_task[id]
	if not current then
		vim.notify("任务树中未找到 ID 为 " .. id .. " 的任务", vim.log.levels.WARN)
		return
	end

	local code_loc = task.locations.code

	-- 同一代码锚点可能关联多个任务，而且这些任务可能分布在不同的 root 任务树里。
	-- 按 root 分组：每个 root 一棵树，各自开一个预览浮窗。
	local groups = {}
	for _, root in ipairs(roots or {}) do
		local all = collect_tasks_iterative(root)
		local anchor_lines = {}
		local seen = {}
		local contains_current = false
		local min_line, max_line = math.huge, -1

		for _, t in ipairs(all) do
			if t.line_num then
				if t.line_num < min_line then
					min_line = t.line_num
				end
				if t.line_num > max_line then
					max_line = t.line_num
				end
			end
			if t.id and t.line_num then
				if t.id == id then
					contains_current = true
				end
				local other = core.get_task(t.id)
				local loc = other and other.locations and other.locations.code
				local same_anchor = code_loc and loc
					and loc.path == code_loc.path
					and loc.line == code_loc.line
				if t.id == id or same_anchor then
					if not seen[t.line_num] then
						seen[t.line_num] = true
						anchor_lines[#anchor_lines + 1] = t.line_num
					end
				end
			end
		end

		if #anchor_lines > 0 and min_line ~= math.huge then
			table.sort(anchor_lines)
			groups[#groups + 1] = {
				min_line = min_line,
				max_line = max_line,
				anchor_lines = anchor_lines,
				contains_current = contains_current,
			}
		end
	end

	if #groups == 0 then
		vim.notify("无法确定任务行范围", vim.log.levels.WARN)
		return
	end

	-- 当前任务所在的树排在最前
	table.sort(groups, function(a, b)
		if a.contains_current ~= b.contains_current then
			return a.contains_current
		end
		return a.min_line < b.min_line
	end)

	local max_trees = config.get("preview.max_trees", DEFAULT_CONFIG.max_trees)
	local max_tree_lines = config.get("preview.max_tree_lines", DEFAULT_CONFIG.max_tree_lines)

	local total_groups = #groups
	local shown_groups = groups
	if total_groups > max_trees then
		shown_groups = {}
		for i = 1, max_trees do
			shown_groups[i] = groups[i]
		end
		vim.notify(
			("该锚点关联 %d 棵任务树，已显示前 %d 棵"):format(total_groups, max_trees),
			vim.log.levels.INFO
		)
	end

	local filename = file.basename(todo_path)
	local do_crop = total_groups > 1

	local specs = {}
	for idx, g in ipairs(shown_groups) do
		local crop_min, crop_max = g.min_line, g.max_line
		if do_crop then
			local span = g.max_line - g.min_line + 1
			if span > max_tree_lines then
				-- 以锚点行为中心裁剪到 max_tree_lines 行
				local lo = g.anchor_lines[1] or g.min_line
				local hi = g.anchor_lines[#g.anchor_lines] or lo
				local room = math.max(0, max_tree_lines - (hi - lo + 1))
				local above = math.floor(room / 2)
				crop_min = math.max(g.min_line, lo - above)
				crop_max = math.min(g.max_line, crop_min + max_tree_lines - 1)
				crop_min = math.max(g.min_line, crop_max - max_tree_lines + 1)
			end
		end

		local preview_lines = {}
		for i = crop_min, crop_max do
			preview_lines[#preview_lines + 1] = lines[i] or ""
		end

		local target_lines = {}
		for _, ln in ipairs(g.anchor_lines) do
			if ln >= crop_min and ln <= crop_max then
				target_lines[#target_lines + 1] = ln - crop_min + 1
			end
		end
		if #target_lines == 0 then
			target_lines[1] = math.max(1, (g.anchor_lines[1] or crop_min) - crop_min + 1)
		end

		local title = " " .. filename
		if total_groups > 1 then
			title = title .. (" (%d/%d)"):format(idx, #shown_groups)
		end
		if crop_max - crop_min + 1 < g.max_line - g.min_line + 1 then
			title = title .. " ✂"
		end
		title = title .. " "

		specs[#specs + 1] = {
			lines = preview_lines,
			title = title,
			target = target_lines,
		}
	end

	-- 预计算每个窗口的尺寸，再排版。
	-- 多窗口时用更小的最小宽度，否则两个 60 列的窗口在窄屏上无法并排。
	local measure_min = (#specs > 1) and 30 or nil
	local measured = {}
	local total_width = 0
	local max_height = 0
	for i, s in ipairs(specs) do
		local m = measure_preview(s.lines, measure_min)
		measured[i] = m
		total_width = total_width + m.width
		if m.height > max_height then
			max_height = m.height
		end
	end
	total_width = total_width + DEFAULT_CONFIG.tree_gap * math.max(0, #specs - 1)

	local screen_lines = vim.api.nvim_get_option("lines")
	local screen_cols = vim.api.nvim_get_option("columns")
	local base_row = math.max(1, math.floor((screen_lines - max_height) / 2))

	if #specs == 1 then
		create_preview_window(specs[1].lines, specs[1].title, "markdown",
			DEFAULT_CONFIG.todo_zindex, specs[1].target, "TodoPreviewHighlight", nil, measured[1])
	elseif total_width + 2 <= screen_cols then
		-- 横向并排
		local col = math.max(1, math.floor((screen_cols - total_width) / 2))
		for i, s in ipairs(specs) do
			create_preview_window(s.lines, s.title, "markdown",
				DEFAULT_CONFIG.todo_zindex, s.target, "TodoPreviewHighlight",
				{ relative = "editor", row = base_row, col = col }, measured[i])
			col = col + measured[i].width + DEFAULT_CONFIG.tree_gap
		end
	else
		-- 放不下：从左上角层叠
		for i, s in ipairs(specs) do
			create_preview_window(s.lines, s.title, "markdown",
				DEFAULT_CONFIG.todo_zindex, s.target, "TodoPreviewHighlight",
				{ relative = "editor", row = math.max(1, base_row + (i - 1) * 3), col = 1 + (i - 1) * 4 }, measured[i])
		end
	end
end

---------------------------------------------------------------------
-- 预览代码
---------------------------------------------------------------------

function M.preview_code()
	close_preview_window()

	local id = cursor.get_id()
	if not id then
		return
	end

	local task = core.get_task(id)
	if not task or not task.locations.code then
		vim.notify("未找到对应的代码任务，ID: " .. id, vim.log.levels.WARN)
		return
	end

	local code_path = task.locations.code.path
	local code_line = task.locations.code.line

	local lines, err = read_file_for_preview(code_path)
	if not lines then
		vim.notify("无法读取文件: " .. code_path .. " - " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	local start_line = math.max(1, code_line - 3)
	local end_line = math.min(#lines, code_line + 3)
	local context_lines = {}

	for i = start_line, end_line do
		context_lines[#context_lines + 1] = lines[i]
	end

	local filetype = get_filetype(code_path)
	local filename = file.basename(code_path)
	local title = " " .. filename .. " "
	local target_line = code_line - start_line + 1

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
-- setup
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
