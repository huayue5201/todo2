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
local description = require("todo2.core.description")
local fold = require("todo2.render.fold")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------

local DEFAULT_CONFIG = {
	min_width = 60,
	max_width = 120,
	max_height = 30,
	todo_zindex = 100,
	code_zindex = 200,
	border_chars = 2,
	safety_margin = 2,
	-- 同一代码锚点关联多个任务时，最多展示几个任务块
	max_trees = 2,
	-- 多窗堆叠/并排时的窗口间距（含边框间隔，保证不相互遮盖）
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

---------------------------------------------------------------------
-- 安全读文件
---------------------------------------------------------------------

local function safe_read_file(path)
	local stat = vim.loop.fs_stat(path)
	if not stat then
		return false, "File does not exist: " .. path
	end

	if stat.size > 1024 * 1024 then
		return false, "File too large, skipping preview: " .. path
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if ok and lines then
		return true, lines
	end
	return false, "Cannot read file: " .. path
end

---------------------------------------------------------------------
-- 任务树遍历
---------------------------------------------------------------------

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

local function highlight_key_line(bufnr, line_num, highlight_group)
	highlight_group = highlight_group or "TodoPreviewHighlight"
	ensure_highlight_groups()

	local ns_id = constants.ns("preview_highlight")

	local start_line, end_line = line_num, line_num

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
--- @return table { processed_lines, width, height }
local function measure_preview(lines, min_width_override, max_width_override)
	local max_content_width = get_max_line_width(lines)
	local border_width = DEFAULT_CONFIG.border_chars
	local min_width = min_width_override or DEFAULT_CONFIG.min_width
	local max_width = max_width_override or DEFAULT_CONFIG.max_width
	local margin = DEFAULT_CONFIG.safety_margin

	local content_chars = math.ceil(max_content_width)
	if content_chars % 2 == 1 then
		content_chars = content_chars + 1
	end

	local width = content_chars + border_width + margin
	width = math.max(width, min_width)
	width = math.min(width, max_width)
	width = math.floor(width)

	local height = math.min(#lines, DEFAULT_CONFIG.max_height)
	return {
		processed_lines = lines,
		width = width,
		height = height,
	}
end

--- 创建预览窗口。
--- @param pos table|nil { relative, row, col, width, height }；为空则相对光标定位
--- @param measured table|nil measure_preview 的结果（多窗口排版时预计算）
--- @return table preview 记录
local function create_preview_window(lines, title, filetype, zindex, target_line_num, highlight_group, pos, measured)
	measured = measured or measure_preview(lines)
	local processed_lines = measured.processed_lines
	local final_width = measured.width
	local height = measured.height

	local relative = "cursor"
	local row, col
	if pos then
		relative = pos.relative or "cursor"
		row = pos.row or 1
		col = pos.col or 1
		if pos.width then
			final_width = pos.width
		end
		if pos.height then
			height = pos.height
		end
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

	-- 预览窗口禁用自动换行：长行横向溢出而非折行
	vim.api.nvim_set_option_value("wrap", false, { scope = "local", win = win })
	vim.api.nvim_set_option_value("linebreak", false, { scope = "local", win = win })
	vim.api.nvim_set_option_value("number", false, { scope = "local", win = win })
	vim.api.nvim_set_option_value("relativenumber", false, { scope = "local", win = win })
	vim.api.nvim_set_option_value("cursorline", false, { scope = "local", win = win })
	-- 内容不足窗口高度时，避免末尾出现 `~` 填充符
	vim.api.nvim_set_option_value("fillchars", "eob: ", { scope = "local", win = win })

	local target_lines = type(target_line_num) == "table" and target_line_num or { target_line_num }
	if #target_lines == 0 then
		target_lines = { 1 }
	end

	local preview = { win = win }
	active_previews[#active_previews + 1] = preview

	for _, tl in ipairs(target_lines) do
		highlight_key_line(bufnr, tl, highlight_group)
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
		vim.notify("No matching TODO task found, ID: " .. id, vim.log.levels.WARN)
		return
	end

	local todo_path = task.locations.todo.path

	local lines, err = read_file_for_preview(todo_path)
	if not lines then
		vim.notify("Cannot read file: " .. todo_path .. " - " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	local roots, id_to_task = get_parse_tree(todo_path)
	local current = id_to_task and id_to_task[id]
	if not current then
		vim.notify("Task with ID " .. id .. " not found in the task tree", vim.log.levels.WARN)
		return
	end

	local code_loc = task.locations.code
	local filename = file.basename(todo_path)

	-- 正文折叠表：任务行 → 正文块（description.fold 关闭时不做折叠展示）
	local desc_blocks = config.get("description.fold") and description.scan(lines) or nil

	-- 在一行任务后追加其折叠的正文占位（`¶ N lines 首行`）
	local function push_folded(out, t)
		if not t.line_num then
			return
		end
		out[#out + 1] = lines[t.line_num] or ""
		local block = desc_blocks and desc_blocks[t.line_num]
		if block then
			out[#out + 1] = fold.collapsed_line(lines[block.start_line] or "", block.end_line - block.start_line + 1)
		end
	end

	-- 收集所有命中锚点的任务（当前任务 + 与同一代码锚点关联的任务），每个任务一块。
	-- 携带祖先链：预览只展示「祖先 → 目标 → 直接子任务」，不铺整棵树。
	local blocks = {}
	local function visit(node, ancestors)
		local is_current = node.id == id
		local same_anchor = false
		if not is_current and code_loc and node.id then
			local other = core.get_task(node.id)
			local loc = other and other.locations and other.locations.code
			same_anchor = (loc and loc.path == code_loc.path and loc.line == code_loc.line) or false
		end
		if is_current or same_anchor then
			blocks[#blocks + 1] = { node = node, ancestors = ancestors, is_current = is_current }
		end
		local next_ancestors = {}
		for i = 1, #ancestors do
			next_ancestors[i] = ancestors[i]
		end
		next_ancestors[#next_ancestors + 1] = node
		for _, child in ipairs(node.children or {}) do
			visit(child, next_ancestors)
		end
	end
	for _, root in ipairs(roots or {}) do
		visit(root, {})
	end

	if #blocks == 0 then
		vim.notify("Cannot determine the task line range", vim.log.levels.WARN)
		return
	end

	-- 当前任务所在的块排在最前
	table.sort(blocks, function(a, b)
		if a.is_current ~= b.is_current then
			return a.is_current
		end
		return (a.node.line_num or 0) < (b.node.line_num or 0)
	end)

	local max_targets = config.get("preview.max_trees", DEFAULT_CONFIG.max_trees)
	local total_blocks = #blocks
	local shown_blocks = blocks
	if total_blocks > max_targets then
		shown_blocks = {}
		for i = 1, max_targets do
			shown_blocks[i] = blocks[i]
		end
		vim.notify(
			("This anchor links %d tasks; showing the first %d"):format(total_blocks, max_targets),
			vim.log.levels.INFO
		)
	end

	-- 组装每块：祖先链（正文折叠，超过 3 级省略中间）+ 目标任务（正文全展开）+ 直接子任务（正文折叠，最多 6 条）
	local child_cap = 6
	local specs = {}
	for idx, b in ipairs(shown_blocks) do
		local out = {}
		local ancestors = b.ancestors
		if #ancestors > 3 then
			push_folded(out, ancestors[1])
			out[#out + 1] = "  …"
			push_folded(out, ancestors[#ancestors])
		else
			for _, a in ipairs(ancestors) do
				push_folded(out, a)
			end
		end

		local target_line = #out + 1
		out[#out + 1] = lines[b.node.line_num] or ""
		local target_block = desc_blocks and desc_blocks[b.node.line_num]
		if target_block then
			for i = target_block.start_line, target_block.end_line do
				out[#out + 1] = lines[i] or ""
			end
		end

		local children = b.node.children or {}
		local shown = math.min(#children, child_cap)
		for i = 1, shown do
			push_folded(out, children[i])
		end
		if #children > shown then
			out[#out + 1] = ("  … 还有 %d 项"):format(#children - shown)
		end

		local title = " " .. filename
		if total_blocks > 1 then
			title = title .. (" (%d/%d)"):format(idx, #shown_blocks)
		end
		title = title .. " "

		specs[#specs + 1] = {
			lines = out,
			title = title,
			target = { target_line },
		}
	end

	-- 预计算尺寸并排版：优先上下堆叠（当前任务所在的块在最上），屏幕放不下再左右并排。
	local screen_lines = vim.api.nvim_get_option("lines")
	local screen_cols = vim.api.nvim_get_option("columns")
	local gap = DEFAULT_CONFIG.tree_gap

	local measure_min = (#specs > 1) and 30 or nil
	local measured = {}
	local total_height = 0
	for i, s in ipairs(specs) do
		local m = measure_preview(s.lines, measure_min)
		measured[i] = m
		total_height = total_height + m.height
	end
	total_height = total_height + gap * (#specs - 1)

	-- 每一行都水平居中
	local function center_col(w)
		return math.max(1, math.floor((screen_cols - w) / 2))
	end

	if #specs == 1 then
		create_preview_window(
			specs[1].lines,
			specs[1].title,
			"markdown",
			DEFAULT_CONFIG.todo_zindex,
			specs[1].target,
			"TodoPreviewHighlight",
			nil,
			measured[1]
		)
	elseif total_height + 2 <= screen_lines then
		-- 上下堆叠
		local row = math.max(1, math.floor((screen_lines - total_height) / 2))
		for i, s in ipairs(specs) do
			create_preview_window(
				s.lines,
				s.title,
				"markdown",
				DEFAULT_CONFIG.todo_zindex,
				s.target,
				"TodoPreviewHighlight",
				{ relative = "editor", row = row, col = center_col(measured[i].width) },
				measured[i]
			)
			row = row + measured[i].height + gap
		end
	else
		-- 上下放不下：左右并排，按屏幕宽度平分每个窗宽，避免重叠
		local avail = screen_cols - 2 - gap * (#specs - 1)
		local per_max = math.floor(avail / #specs)
		if per_max < measure_min then
			vim.notify("Screen too small for multiple task blocks; showing only the first", vim.log.levels.INFO)
			local m = measure_preview(specs[1].lines)
			create_preview_window(
				specs[1].lines,
				specs[1].title,
				"markdown",
				DEFAULT_CONFIG.todo_zindex,
				specs[1].target,
				"TodoPreviewHighlight",
				nil,
				m
			)
		else
			local total_width = 0
			local max_height = 0
			for i, s in ipairs(specs) do
				local m = measure_preview(s.lines, measure_min, per_max)
				measured[i] = m
				total_width = total_width + m.width
				if m.height > max_height then
					max_height = m.height
				end
			end
			total_width = total_width + gap * (#specs - 1)
			local row = math.max(1, math.floor((screen_lines - max_height) / 2))
			local col = math.max(1, math.floor((screen_cols - total_width) / 2))
			for i, s in ipairs(specs) do
				create_preview_window(
					s.lines,
					s.title,
					"markdown",
					DEFAULT_CONFIG.todo_zindex,
					s.target,
					"TodoPreviewHighlight",
					{ relative = "editor", row = row, col = col },
					measured[i]
				)
				col = col + measured[i].width + gap
			end
		end
	end
end

---------------------------------------------------------------------
-- 预览代码
---------------------------------------------------------------------

--- 计算贴附在某工作窗口（如抽屉）一侧的布局参数。
--- 参考 neo-tree 的 preview：优先放右侧，右侧空间不足放左侧；与锚点窗口同高。
---@param anchor_win integer
---@return table {row, col, width, height, side, avail, gap}
local function anchor_layout(anchor_win)
	local p = vim.api.nvim_win_get_position(anchor_win)
	local aw = vim.api.nvim_win_get_width(anchor_win)
	local ah = vim.api.nvim_win_get_height(anchor_win)
	local gap = 2
	local right = vim.o.columns - (p[2] + aw) - gap - 2
	local left = p[2] - gap - 2
	local side, avail
	if right >= left then
		side, avail = "right", right
	else
		side, avail = "left", left
	end
	return { row = p[1], col = p[2], width = aw, height = ah, side = side, avail = avail, gap = gap }
end

--- 预览指定任务代码锚点附近的上下文（默认 ±3 行）。供光标预览与抽屉共用。
---@param task table|nil 完整任务对象（含 locations.code）
---@param opts table|nil { anchor_win = integer } 指定则贴附该窗口一侧（编辑器相对）
function M.preview_code_task(task, opts)
	close_preview_window()

	if not task or not task.locations or not task.locations.code then
		vim.notify("No matching code task found", vim.log.levels.WARN)
		return
	end

	local code_path = task.locations.code.path
	local code_line = task.locations.code.line

	local lines, err = read_file_for_preview(code_path)
	if not lines then
		vim.notify("Cannot read file: " .. code_path .. " - " .. tostring(err), vim.log.levels.ERROR)
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

	-- 贴附锚点窗口（抽屉）时：按可用宽度测量、与锚点同高、编辑器相对定位
	local pos, measured
	local anchor_win = opts and opts.anchor_win
	if anchor_win and vim.api.nvim_win_is_valid(anchor_win) then
		local layout = anchor_layout(anchor_win)
		if layout.avail >= DEFAULT_CONFIG.min_width then
			local max_w = math.min(DEFAULT_CONFIG.max_width, layout.avail)
			measured = measure_preview(context_lines, nil, max_w)
			local col
			if layout.side == "right" then
				col = layout.col + layout.width + layout.gap
			else
				col = math.max(0, layout.col - layout.gap - measured.width)
			end
			pos = {
				relative = "editor",
				row = layout.row,
				col = col,
				width = measured.width,
				-- 高度按内容自适应，最多不超过锚点窗口高度
				height = math.min(layout.height, measured.height),
			}
		end
	end

	create_preview_window(
		context_lines,
		title,
		filetype,
		DEFAULT_CONFIG.code_zindex,
		target_line,
		"CodePreviewHighlight",
		pos,
		measured
	)
end

--- 预览光标所在任务的代码锚点（TODO buffer 用）。
function M.preview_code()
	local id = cursor.get_id()
	if not id then
		close_preview_window()
		return
	end
	M.preview_code_task(core.get_task(id))
end

return M
