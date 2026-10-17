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
	-- 同一代码锚点关联多个任务时的安全上限（防止病态 fan-out 撑爆窗口数）
	max_blocks = 20,
	-- 平铺窗格的最小高度；低于此值退化为单窗滚动列表
	min_pane_height = 3,
	-- 平铺窗格之间的间距（共边框视觉，尽量小）
	tile_gap = 2,
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
	local screen_width = vim.o.columns
	local screen_height = vim.o.lines
	-- winline()/wincol() 是「当前窗口内」坐标，必须加上窗口原点才是屏幕坐标。
	local win_pos = vim.api.nvim_win_get_position(0)
	local cursor_screen_row = win_pos[1] + vim.fn.winline()
	local cursor_screen_col = win_pos[2] + vim.fn.wincol()

	local row = 1
	local col = 2

	if cursor_screen_col + width > screen_width - 5 then
		col = -width + 2
	end

	if cursor_screen_row + height > screen_height - 2 then
		row = -height - 1
	end

	if cursor_screen_col + col < 2 then
		col = 2 - cursor_screen_col
	end

	-- 垂直方向同样回夹：光标靠近屏幕顶部时，上翻会整窗顶出屏幕。
	if cursor_screen_row + row < 1 then
		row = 1 - cursor_screen_row
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
        highlight default CodeAnchorSpan guibg=#ffaa00 guifg=#000000 gui=bold
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

	local height = math.max(1, math.min(#lines, DEFAULT_CONFIG.max_height))
	return {
		processed_lines = lines,
		width = width,
		height = height,
	}
end

--- 创建预览窗口。
--- @param pos table|nil { relative, row, col, width, height }；为空则相对光标定位
--- @param measured table|nil measure_preview 的结果（多窗口排版时预计算）
--- @param focus_col? integer 0-based byte 列：预览要定位到的列
--- @param focus_end_col? integer 0-based byte 结束列（不含）
--- @return table preview 记录
local function create_preview_window(
	lines,
	title,
	filetype,
	zindex,
	target_line_num,
	highlight_group,
	pos,
	measured,
	focus_col,
	focus_end_col
)
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

	local ok_open, win = pcall(vim.api.nvim_open_win, bufnr, false, {
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
	if not ok_open then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		vim.notify("Failed to open preview: " .. tostring(win), vim.log.levels.ERROR)
		return nil
	end

	-- 先注册再设置窗口选项：任何一步抛错都不会留下无人收管的浮窗。
	local preview = { win = win }
	active_previews[#active_previews + 1] = preview

	local ok_setup = pcall(function()
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

		for _, tl in ipairs(target_lines) do
			highlight_key_line(bufnr, tl, highlight_group)
		end

		-- 代码锚点的精确列：把光标移到列上并高亮 token 区间。
		if focus_col ~= nil then
			local tl = target_lines[1]
			local text = processed_lines[tl] or ""
			local c = math.max(0, math.min(math.floor(focus_col), #text))
			local e = focus_end_col and math.max(c, math.min(math.floor(focus_end_col), #text)) or c
			pcall(vim.api.nvim_win_set_cursor, win, { tl, c })
			if e > c then
				pcall(
					vim.api.nvim_buf_add_highlight,
					bufnr,
					constants.ns("preview_highlight"),
					"CodeAnchorSpan",
					tl - 1,
					c,
					e
				)
			end
		end

		-- markdown（TODO）预览复用 todo2 渲染管线：复选框、状态色、进度、标签、删除线、折叠。
		if filetype == "markdown" then
			pcall(function()
				require("todo2.render.todo_render").render(bufnr)
				require("todo2.render.conceal").apply_buffer_conceal(bufnr)
			end)
		end
	end)
	if not ok_setup then
		close_preview_window()
		return nil
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
	if not result or #result == 0 then
		return nil, "empty file"
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
	local function push_folded(out, t, flines, fdesc)
		if not t.line_num then
			return
		end
		out[#out + 1] = flines[t.line_num] or ""
		local block = fdesc and fdesc[t.line_num]
		if block then
			out[#out + 1] = fold.collapsed_line(flines[block.start_line] or "", block.end_line - block.start_line + 1)
		end
	end

	-- 在指定文件树中定位任务节点及其祖先链。
	local function node_and_ancestors(froots, node_id)
		local found_node, found_anc
		local function find(n, chain)
			if n.id == node_id then
				found_node, found_anc = n, chain
				return true
			end
			local next_chain = {}
			for i = 1, #chain do
				next_chain[i] = chain[i]
			end
			next_chain[#next_chain + 1] = n
			for _, child in ipairs(n.children or {}) do
				if find(child, next_chain) then
					return true
				end
			end
			return false
		end
		for _, root in ipairs(froots) do
			if find(root, {}) then
				break
			end
		end
		return found_node, found_anc
	end

	-- 收集所有命中锚点的任务（当前任务 + 与同一代码锚点关联的任务，跨 TODO 文件也在内），每个任务一块。
	-- 携带祖先链：预览只展示「祖先 → 目标 → 直接子任务」，不铺整棵树。
	local blocks = {}
	local seen = {}
	local file_cache = {}
	local function add_block(t)
		if not t or not t.id or seen[t.id] then
			return
		end
		local tp = t.locations and t.locations.todo and t.locations.todo.path
		if not tp then
			return
		end
		seen[t.id] = true

		local flines, fdesc, froots, fname
		if tp == todo_path then
			flines, fdesc, froots, fname = lines, desc_blocks, roots, filename
		else
			local cache = file_cache[tp]
			if not cache then
				local l = read_file_for_preview(tp)
				if not l then
					return
				end
				local r = get_parse_tree(tp)
				cache = {
					lines = l,
					roots = r or {},
					desc = config.get("description.fold") and description.scan(l) or nil,
					name = file.basename(tp),
				}
				file_cache[tp] = cache
			end
			flines, fdesc, froots, fname = cache.lines, cache.desc, cache.roots, cache.name
		end

		local node, ancestors = node_and_ancestors(froots, t.id)
		if node then
			blocks[#blocks + 1] = {
				node = node,
				ancestors = ancestors,
				is_current = (t.id == id),
				lines = flines,
				desc_blocks = fdesc,
				filename = fname,
			}
		end
	end

	-- 当前任务优先，再补齐同一代码锚点上的其他任务（可能位于别的 TODO 文件）。
	add_block(task)
	if code_loc and code_loc.path then
		local index = require("todo2.store.index")
		for _, t in ipairs(index.find_code_links_by_file(code_loc.path) or {}) do
			local loc = t.locations and t.locations.code
			if loc and loc.path == code_loc.path and loc.line == code_loc.line then
				add_block(t)
			end
		end
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

	local max_blocks = config.get("preview.max_blocks", DEFAULT_CONFIG.max_blocks)
	local shown_blocks = blocks
	if #blocks > max_blocks then
		shown_blocks = {}
		for i = 1, max_blocks do
			shown_blocks[i] = blocks[i]
		end
		vim.notify(
			("This anchor links %d tasks; showing the first %d"):format(#blocks, max_blocks),
			vim.log.levels.INFO
		)
	end
	local total_blocks = #shown_blocks

	-- 组装每块：祖先链（正文折叠，超过 3 级省略中间）+ 目标任务（正文全展开）+ 直接子任务（正文折叠，最多 6 条）
	local child_cap = 6
	local specs = {}
	for idx, b in ipairs(shown_blocks) do
		local out = {}
		local lines = b.lines
		local desc_blocks = b.desc_blocks
		local ancestors = b.ancestors
		if #ancestors > 3 then
			push_folded(out, ancestors[1], lines, desc_blocks)
			out[#out + 1] = "  …"
			push_folded(out, ancestors[#ancestors], lines, desc_blocks)
		else
			for _, a in ipairs(ancestors) do
				push_folded(out, a, lines, desc_blocks)
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
			push_folded(out, children[i], lines, desc_blocks)
		end
		if #children > shown then
			out[#out + 1] = ("  … 还有 %d 项"):format(#children - shown)
		end

		local title = " " .. b.filename
		if total_blocks > 1 then
			title = title .. (" (%d/%d)"):format(idx, total_blocks)
		end
		title = title .. " "

		specs[#specs + 1] = {
			lines = out,
			title = title,
			target = { target_line },
		}
	end

	-- 排版：单块沿用内容自适应；多块采用平铺（等分填充），几何放不下时退化为单窗滚动列表。
	local screen_lines = vim.o.lines
	local screen_cols = vim.o.columns
	local gap = DEFAULT_CONFIG.tile_gap

	if #specs == 1 then
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
		return
	end

	local measure_min = DEFAULT_CONFIG.min_width
	local max_content_h = 1
	local max_content_w = measure_min
	for _, s in ipairs(specs) do
		local m = measure_preview(s.lines, measure_min)
		max_content_h = math.max(max_content_h, m.height)
		max_content_w = math.max(max_content_w, m.width)
	end

	local n = #specs
	local pane_w = math.min(max_content_w, screen_cols - 2)
	local equal_h = math.floor((screen_lines - 2 - gap * (n - 1)) / n)
	local pane_h = math.min(math.max(max_content_h, DEFAULT_CONFIG.min_pane_height), equal_h)

	if pane_h < DEFAULT_CONFIG.min_pane_height or pane_w < measure_min then
		-- 几何放不下：单窗纵向滚动，所有任务用分隔线顺次排列（不丢弃任何任务）
		local combined = {}
		local targets = {}
		for i, s in ipairs(specs) do
			if i > 1 then
				combined[#combined + 1] = ""
			end
			combined[#combined + 1] = ("── %s ──"):format(vim.trim(s.title))
			local base = #combined
			for _, l in ipairs(s.lines) do
				combined[#combined + 1] = l
			end
			for _, t in ipairs(s.target) do
				targets[#targets + 1] = base + t
			end
		end
		local m = measure_preview(combined, measure_min, screen_cols - 2)
		m.height = math.min(#combined, screen_lines - 2)
		create_preview_window(
			combined,
			(" %d tasks "):format(#specs),
			"markdown",
			DEFAULT_CONFIG.todo_zindex,
			targets,
			"TodoPreviewHighlight",
			nil,
			m
		)
		return
	end

	-- 等分平铺：N 块同宽等高、紧密堆叠，贴附光标列，整组相对编辑器定位。
	local region_h = pane_h * n + gap * (n - 1)
	local win_pos = vim.api.nvim_win_get_position(0)
	local cur_row = win_pos[1] + vim.fn.winline()
	local cur_col = win_pos[2] + vim.fn.wincol()

	local col = cur_col + 2
	if col + pane_w > screen_cols - 1 then
		col = cur_col - pane_w
	end
	col = math.max(0, math.min(col, math.max(0, screen_cols - pane_w - 1)))
	local row = math.max(0, math.min(cur_row - 1, math.max(0, screen_lines - region_h - 1)))

	for i, s in ipairs(specs) do
		create_preview_window(
			s.lines,
			s.title,
			"markdown",
			DEFAULT_CONFIG.todo_zindex,
			s.target,
			"TodoPreviewHighlight",
			{ relative = "editor", row = row, col = col, width = pane_w, height = pane_h },
			{ width = pane_w, height = pane_h, processed_lines = s.lines }
		)
		row = row + pane_h + gap
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

	if not task or not task.locations then
		vim.notify("No matching code task found", vim.log.levels.WARN)
		return
	end

	-- 自身没有可用锚点时，回退到最近祖先的锚点（补充任务继承代码锚点）。
	local code_loc = task.locations.code
	if task.id and (not code_loc or core.is_anchor_lost(task)) then
		local loc = require("todo2.store.task.query").resolve_code_location(task.id)
		if loc then
			code_loc = loc
		end
	end

	if not code_loc or not code_loc.path or type(code_loc.line) ~= "number" then
		vim.notify("No matching code task found", vim.log.levels.WARN)
		return
	end

	local code_path = code_loc.path
	local code_line = code_loc.line

	local lines, err = read_file_for_preview(code_path)
	if not lines or #lines == 0 then
		vim.notify("Cannot read file: " .. code_path .. " - " .. tostring(err or "empty file"), vim.log.levels.ERROR)
		return
	end

	-- 陈旧锚点可能超出当前文件长度：夹紧到有效行，避免上下文为空。
	code_line = math.max(1, math.min(code_line, #lines))

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

	-- 精确列：夹紧到当前行长度，行内编辑后旧列不会越界。
	local focus_col, focus_end_col
	if type(code_loc.col) == "number" then
		local line_text = lines[code_line] or ""
		focus_col = math.max(0, math.min(math.floor(code_loc.col), #line_text))
		if type(code_loc.end_col) == "number" then
			focus_end_col = math.max(focus_col, math.min(math.floor(code_loc.end_col), #line_text))
		end
	end

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
		measured,
		focus_col,
		focus_end_col
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
