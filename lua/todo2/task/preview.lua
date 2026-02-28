-- lua/todo2/link/preview.lua
--- @module todo2.link.preview
--- @brief 预览 TODO 或代码（完整任务树，不受 context_split 影响）
--- @description 支持中文显示优化，使用显示宽度计算窗口大小，修复中文截断问题
--- @version 2.1.0

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local parser = require("todo2.core.parser")
local store_link = require("todo2.store.link")
local id_utils = require("todo2.utils.id") -- 新增依赖

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------

-- 默认窗口配置
local DEFAULT_CONFIG = {
	min_width = 60,
	max_width = 120,
	padding = 8,
	max_height = 30,
	todo_zindex = 100,
	code_zindex = 200,
	border_chars = 2, -- 边框占用的字符数（rounded边框左右各1）
	safety_margin = 2, -- 安全边距
}

-- 当前预览窗口信息
local current_preview = {
	win = nil,
	buf = nil,
	type = nil, -- 'todo' 或 'code'
	win_close_autocmd = nil, -- 窗口关闭监听ID
}

-- 光标位置监听ID
local cursor_autocmd_id = nil

---------------------------------------------------------------------
-- 工具函数：显示宽度处理（支持中文）- 修复版
---------------------------------------------------------------------

--- 获取字符串在屏幕上的精确显示宽度
--- @param str string 要计算的字符串
--- @return integer 显示宽度
local function get_display_width(str)
	if not str or str == "" then
		return 0
	end
	-- 使用 Neovim 内置函数获取显示宽度
	local ok, width = pcall(vim.fn.strdisplaywidth, str)
	if ok and width then
		return width
	end
	-- 降级方案：精确估算（中文按2，英文按1，其他组合字符特殊处理）
	local len = 0
	local i = 1
	while i <= #str do
		local char = str:sub(i, i)
		local byte = char:byte()
		if byte < 128 then
			-- ASCII字符
			len = len + 1
			i = i + 1
		elseif byte >= 192 and byte <= 223 then
			-- 2字节UTF-8字符（通常是各种符号，算1.5？但这里简化算2）
			len = len + 2
			i = i + 2
		elseif byte >= 224 and byte <= 239 then
			-- 3字节UTF-8字符（中文等，算2）
			len = len + 2
			i = i + 3
		elseif byte >= 240 and byte <= 247 then
			-- 4字节UTF-8字符（emoji等，算2）
			len = len + 2
			i = i + 4
		else
			i = i + 1
		end
	end
	return len
end

--- 计算精确的窗口宽度（修复中文显示不全问题）
--- @param lines table 行列表
--- @param min_width integer 最小宽度
--- @param max_width integer 最大宽度
--- @param border_width integer 边框占用的宽度
--- @param margin integer 安全边距
--- @return integer 精确的窗口宽度
local function calculate_exact_window_width(lines, min_width, max_width, border_width, margin)
	border_width = border_width or DEFAULT_CONFIG.border_chars
	margin = margin or DEFAULT_CONFIG.safety_margin
	min_width = min_width or DEFAULT_CONFIG.min_width
	max_width = max_width or DEFAULT_CONFIG.max_width

	-- 获取最大内容显示宽度
	local max_content_width = 0
	for _, line in ipairs(lines) do
		local display_width = get_display_width(line)
		if display_width > max_content_width then
			max_content_width = display_width
		end
	end

	-- 关键修复：内容宽度需要向上取整到整数
	-- 因为窗口宽度必须是整数
	local content_chars = math.ceil(max_content_width)

	-- 确保宽度是偶数（中文字符通常成对出现，偶数宽度更安全）
	if content_chars % 2 == 1 then
		content_chars = content_chars + 1
	end

	-- 总宽度 = 内容宽度 + 边框宽度 + 安全边距
	-- 边框占用左右各 border_width/2 个字符
	-- 安全边距提供额外的缓冲空间
	local total_width = content_chars + border_width + margin

	-- 确保不低于最小宽度，不超过最大宽度
	total_width = math.max(total_width, min_width)
	total_width = math.min(total_width, max_width)

	-- 再次确保最终宽度是整数
	total_width = math.floor(total_width)

	return total_width
end

--- 检查行是否会被截断
--- @param line string 要检查的行
--- @param window_width integer 窗口宽度（字符数）
--- @param border_width integer 边框宽度
--- @return boolean 是否会被截断
local function will_be_truncated(line, window_width, border_width)
	border_width = border_width or DEFAULT_CONFIG.border_chars
	local display_width = get_display_width(line)
	-- 减去边框占用的宽度
	local available_width = window_width - border_width
	return display_width > available_width
end

--- 获取确保所有行都能完整显示的最小宽度
--- @param lines table 行列表
--- @param border_width integer 边框宽度
--- @param margin integer 安全边距
--- @return integer 最小所需宽度
local function get_minimum_width_for_lines(lines, border_width, margin)
	border_width = border_width or DEFAULT_CONFIG.border_chars
	margin = margin or DEFAULT_CONFIG.safety_margin

	local max_needed = 0
	for _, line in ipairs(lines) do
		local width = get_display_width(line)
		max_needed = math.max(max_needed, width)
	end

	-- 计算所需的总窗口宽度
	local needed = math.ceil(max_needed) + border_width + margin
	-- 确保是偶数
	if needed % 2 == 1 then
		needed = needed + 1
	end

	return needed
end

---------------------------------------------------------------------
-- 工具函数：安全读取文件（支持编码检测）
---------------------------------------------------------------------

--- 安全读取文件，支持编码处理
--- @param path string 文件路径
--- @return boolean 是否成功
--- @return table|string 成功返回行列表，失败返回错误信息
local function safe_read_file(path)
	-- 检查文件是否存在
	local stat = vim.loop.fs_stat(path)
	if not stat then
		return false, "文件不存在: " .. path
	end

	-- 检查文件大小（避免读取超大文件）
	if stat.size > 1024 * 1024 then -- 大于1MB
		return false, "文件过大，跳过预览: " .. path
	end

	-- 尝试以 UTF-8 读取
	local ok, lines = pcall(vim.fn.readfile, path)
	if ok then
		return true, lines
	end

	-- 如果失败，尝试使用 vim.loop.fs_open 读取原始数据
	local fd = vim.loop.fs_open(path, "r", 438)
	if not fd then
		return false, "无法打开文件: " .. path
	end

	local stat = vim.loop.fs_fstat(fd)
	local data = vim.loop.fs_read(fd, stat.size, 0)
	vim.loop.fs_close(fd)

	if not data then
		return false, "无法读取文件内容: " .. path
	end

	-- 尝试检测编码并转换
	-- 检查是否为 UTF-8
	local is_utf8 = true
	for i = 1, math.min(100, #data) do -- 只检查前100字节
		local byte = data:byte(i)
		if byte and byte >= 0x80 then
			-- 简单的 UTF-8 检测
			if byte >= 0xC0 and byte <= 0xDF then
				-- 2字节UTF-8，需要检查下一个字节
				if not data:byte(i + 1) or data:byte(i + 1) < 0x80 or data:byte(i + 1) > 0xBF then
					is_utf8 = false
					break
				end
				i = i + 1
			elseif byte >= 0xE0 and byte <= 0xEF then
				-- 3字节UTF-8
				if not data:byte(i + 1) or not data:byte(i + 2) then
					is_utf8 = false
					break
				end
				i = i + 2
			elseif byte >= 0xF0 and byte <= 0xF7 then
				-- 4字节UTF-8
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
		-- 尝试作为 GBK 处理（简化版）
		-- 这里可以集成 iconv 或使用第三方库
		return false, "文件编码不是 UTF-8，建议转换后重试"
	end

	-- 按行分割
	local lines = {}
	for line in data:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	return true, lines
end

---------------------------------------------------------------------
-- 工具函数：迭代收集任务（避免递归栈溢出）
---------------------------------------------------------------------

--- 迭代收集任务树中的所有任务
--- @param root table 根任务
--- @return table 所有任务列表
local function collect_tasks_iterative(root)
	local all = {}
	local stack = { root }
	local visited = {} -- 防止循环引用

	while #stack > 0 do
		local current = table.remove(stack)

		-- 防止循环引用
		if visited[current] then
			goto continue
		end
		visited[current] = true

		table.insert(all, current)

		-- 将子任务推入栈（使用后进先出，模拟深度优先）
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
-- 工具函数：计算窗口位置（避免屏幕边缘问题）- 增强版
---------------------------------------------------------------------

--- 计算窗口位置，避免屏幕边缘
--- @param width integer 窗口宽度
--- @param height integer 窗口高度
--- @return integer row 行偏移
--- @return integer col 列偏移
local function calculate_window_position(width, height)
	-- 获取光标位置
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor_pos[1]
	local cursor_col = cursor_pos[2]

	-- 获取窗口和屏幕信息
	local win_width = vim.api.nvim_get_option("columns")
	local win_height = vim.api.nvim_get_option("lines")
	local cursor_screen_row = vim.fn.winline() -- 光标在当前窗口的行号
	local cursor_screen_col = vim.fn.wincol() -- 光标在当前窗口的列号

	-- 默认位置（光标下方偏右一点，避免遮挡光标所在行）
	local row = 1
	local col = 2

	-- 检查右边界（留5个字符的缓冲）
	if cursor_screen_col + width > win_width - 5 then
		col = -width + 2 -- 向左偏移，但保留一点右边距
	end

	-- 检查下边界
	if cursor_screen_row + height > win_height - 2 then
		row = -height - 1 -- 向上偏移
	end

	-- 检查左边界
	if cursor_screen_col + col < 2 then
		col = 2 - cursor_screen_col -- 确保不超出左边界
	end

	return row, col
end

---------------------------------------------------------------------
-- 工具函数：关闭预览窗口
---------------------------------------------------------------------
local function close_preview_window()
	if current_preview.win and vim.api.nvim_win_is_valid(current_preview.win) then
		pcall(vim.api.nvim_win_close, current_preview.win, true)
	end

	-- 清理资源
	if current_preview.win_close_autocmd then
		pcall(vim.api.nvim_del_autocmd, current_preview.win_close_autocmd)
	end

	current_preview.win = nil
	current_preview.buf = nil
	current_preview.type = nil
	current_preview.win_close_autocmd = nil

	-- 清除光标监听
	if cursor_autocmd_id then
		pcall(vim.api.nvim_del_autocmd, cursor_autocmd_id)
		cursor_autocmd_id = nil
	end
end

---------------------------------------------------------------------
-- 工具函数：设置窗口关闭监听
---------------------------------------------------------------------
local function setup_win_close_listener(win, bufnr)
	-- 先清除旧的监听
	if current_preview.win_close_autocmd then
		pcall(vim.api.nvim_del_autocmd, current_preview.win_close_autocmd)
	end

	-- 创建新的监听
	current_preview.win_close_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
		buffer = bufnr,
		callback = function()
			if current_preview.win == win then
				current_preview.win = nil
				current_preview.buf = nil
				current_preview.type = nil
				current_preview.win_close_autocmd = nil
			end
			-- 清除光标监听
			if cursor_autocmd_id then
				pcall(vim.api.nvim_del_autocmd, cursor_autocmd_id)
				cursor_autocmd_id = nil
			end
		end,
	})
end

---------------------------------------------------------------------
-- 工具函数：设置光标监听
---------------------------------------------------------------------
local function setup_cursor_listener()
	-- 先清除旧的监听
	if cursor_autocmd_id then
		pcall(vim.api.nvim_del_autocmd, cursor_autocmd_id)
	end

	-- 创建新的监听
	cursor_autocmd_id = vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		callback = function()
			close_preview_window()
		end,
	})
end

---------------------------------------------------------------------
-- 工具函数：确保高亮组存在
---------------------------------------------------------------------
local function ensure_highlight_groups()
	-- 检查并创建默认高亮组
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

	-- 自定义高亮组
	vim.cmd([[
        highlight default TodoPreviewHighlight guibg=#3a3a3a guifg=NONE gui=underline,bold
        highlight default CodePreviewHighlight guibg=#2a4a2a guifg=NONE gui=underline,bold
        highlight default TodoPreviewLeftMarker guibg=#ffaa00 guifg=#000000
    ]])
end

---------------------------------------------------------------------
-- 工具函数：高亮关键行（增强版）
---------------------------------------------------------------------
local function highlight_key_line(bufnr, line_num, highlight_group, total_lines)
	-- 如果预览内容只有一行，不高亮
	if total_lines and total_lines <= 1 then
		return
	end

	-- 如果没指定高亮组，使用默认值
	highlight_group = highlight_group or "TodoPreviewHighlight"

	-- 确保高亮组存在
	ensure_highlight_groups()

	-- 创建命名空间
	local ns_id = vim.api.nvim_create_namespace("todo_preview_highlight")

	-- 清除该行的现有高亮
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, line_num - 1, line_num)

	-- 添加多个高亮效果组合
	local highlights = { "Underlined", "Search", "Bold", "DiffText", highlight_group }

	for _, hl in ipairs(highlights) do
		pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl, line_num - 1, 0, -1)
	end

	-- 添加左边框标记
	pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, "TodoPreviewLeftMarker", line_num - 1, 0, 1)
end

---------------------------------------------------------------------
-- 获取文件类型（使用 Neovim 内置函数）
---------------------------------------------------------------------
--- 根据文件路径获取文件类型
--- @param path string 文件路径
--- @return string 文件类型
local function get_filetype(path)
	-- 直接从文件名获取文件类型
	local ft = vim.filetype.match({ filename = path })

	-- 如果文件名匹配失败，尝试通过文件内容匹配
	if not ft then
		local bufnr = nil
		local ok, result = pcall(function()
			-- 创建一个临时缓冲区
			bufnr = vim.api.nvim_create_buf(false, true)

			-- 读取文件前几行
			local lines = {}
			local ok_read, file_lines = safe_read_file(path)
			if ok_read and type(file_lines) == "table" then
				for i = 1, math.min(5, #file_lines) do
					table.insert(lines, file_lines[i])
				end
			end

			if #lines > 0 then
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
			end

			return vim.filetype.match({ buf = bufnr })
		end)

		-- 确保临时缓冲区被删除
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
			pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		end

		if ok and result then
			ft = result
		end
	end

	return ft or "text"
end

---------------------------------------------------------------------
-- 获取文件名（从路径中）- 支持 Windows 路径
---------------------------------------------------------------------
--- 从文件路径中获取文件名
--- @param path string 文件路径
--- @return string 文件名
local function get_filename(path)
	-- 同时支持 / 和 \ 作为路径分隔符
	local name = path:match("([^/\\]+)$")
	if name then
		-- 移除可能的 Windows 驱动器号
		name = name:gsub("^[A-Za-z]:", "")
		return name
	end
	return path
end

---------------------------------------------------------------------
-- ⭐ 修改：预览 TODO（使用id_utils）
---------------------------------------------------------------------
function M.preview_todo()
	-- 先关闭已有的预览窗口
	close_preview_window()

	local line = vim.fn.getline(".")
	-- ⭐ 使用 id_utils 提取
	if not id_utils.contains_code_mark(line) then
		return
	end

	local tag = id_utils.extract_tag_from_code_mark(line)
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
	local ok, lines = safe_read_file(todo_path)
	if not ok then
		vim.notify("无法读取文件: " .. todo_path .. " - " .. lines, vim.log.levels.ERROR)
		return
	end

	-- 使用完整树解析
	local _, _, id_to_task = parser.parse_file(todo_path)
	local current = id_to_task and id_to_task[id]
	if not current then
		vim.notify("任务树中未找到 ID 为 " .. id .. " 的任务", vim.log.levels.WARN)
		return
	end

	-- 找到根任务
	local root = current
	while root.parent do
		root = root.parent
	end

	-- 迭代收集所有任务
	local all = collect_tasks_iterative(root)

	-- 计算展示范围
	local min_line = math.huge
	local max_line = -1
	for _, t in ipairs(all) do
		if t.line_num then
			min_line = math.min(min_line, t.line_num)
			max_line = math.max(max_line, t.line_num)
		end
	end

	if min_line == math.huge or max_line == -1 then
		vim.notify("无法确定任务行范围", vim.log.levels.WARN)
		return
	end

	-- 收集展示内容
	local preview_lines = {}
	for i = min_line, max_line do
		preview_lines[#preview_lines + 1] = lines[i] or ""
	end

	-- 获取文件名作为标题
	local filename = get_filename(todo_path)

	-- 计算精确的窗口宽度（修复中文截断问题）
	local border_width = DEFAULT_CONFIG.border_chars
	local min_width = DEFAULT_CONFIG.min_width
	local max_width = DEFAULT_CONFIG.max_width
	local margin = DEFAULT_CONFIG.safety_margin

	-- 计算基础宽度
	local width = calculate_exact_window_width(preview_lines, min_width, max_width, border_width, margin)

	-- 二次验证：确保所有行都能完整显示
	local needed_width = get_minimum_width_for_lines(preview_lines, border_width, margin)
	if needed_width > width then
		width = math.min(needed_width, max_width)
	end

	-- 确保宽度是整数且不小于最小宽度
	width = math.max(math.floor(width), min_width)

	-- 计算高度
	local height = math.min(#preview_lines, DEFAULT_CONFIG.max_height)

	-- 计算窗口位置
	local row, col = calculate_window_position(width, height)

	-- 创建浮动预览窗口
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, preview_lines)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")
	vim.api.nvim_buf_set_option(bufnr, "swapfile", false)

	-- 创建窗口
	local win = vim.api.nvim_open_win(bufnr, false, {
		relative = "cursor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = filename,
		title_pos = "center",
		focusable = true,
		zindex = DEFAULT_CONFIG.todo_zindex,
	})

	-- 设置窗口选项
	vim.api.nvim_win_set_option(win, "wrap", false) -- 禁止自动换行，避免破坏格式
	vim.api.nvim_win_set_option(win, "linebreak", false)
	vim.api.nvim_win_set_option(win, "number", false)
	vim.api.nvim_win_set_option(win, "relativenumber", false)
	vim.api.nvim_win_set_option(win, "cursorline", false)

	-- 高亮当前任务行
	local target_line = current.line_num
	local preview_line = target_line - min_line + 1
	if preview_line >= 1 and preview_line <= #preview_lines then
		highlight_key_line(bufnr, preview_line, "TodoPreviewHighlight", #preview_lines)
	end

	-- 保存当前预览窗口信息
	current_preview.win = win
	current_preview.buf = bufnr
	current_preview.type = "todo"

	-- 设置监听
	setup_win_close_listener(win, bufnr)
	setup_cursor_listener()
end

---------------------------------------------------------------------
-- ⭐ 修改：预览代码（使用id_utils）
---------------------------------------------------------------------
function M.preview_code()
	-- 先关闭已有的预览窗口
	close_preview_window()

	local line = vim.fn.getline(".")
	-- ⭐ 使用 id_utils 提取
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

	local ok, lines = safe_read_file(link.path)
	if not ok then
		vim.notify("无法读取文件: " .. link.path .. " - " .. lines, vim.log.levels.ERROR)
		return
	end

	local start_line = math.max(1, link.line - 3)
	local end_line = math.min(#lines, link.line + 3)
	local context_lines = {}

	for i = start_line, end_line do
		context_lines[#context_lines + 1] = lines[i]
	end

	-- 获取文件类型和文件名
	local filetype = get_filetype(link.path)
	local filename = get_filename(link.path)

	-- 计算精确的窗口宽度（修复中文截断问题）
	local border_width = DEFAULT_CONFIG.border_chars
	local min_width = DEFAULT_CONFIG.min_width
	local max_width = DEFAULT_CONFIG.max_width
	local margin = DEFAULT_CONFIG.safety_margin

	-- 计算基础宽度
	local width = calculate_exact_window_width(context_lines, min_width, max_width, border_width, margin)

	-- 二次验证：确保所有行都能完整显示
	local needed_width = get_minimum_width_for_lines(context_lines, border_width, margin)
	if needed_width > width then
		width = math.min(needed_width, max_width)
	end

	-- 确保宽度是整数且不小于最小宽度
	width = math.max(math.floor(width), min_width)

	-- 计算高度
	local height = math.min(#context_lines, DEFAULT_CONFIG.max_height)

	-- 计算窗口位置
	local row, col = calculate_window_position(width, height)

	-- 创建浮动预览窗口
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, context_lines)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(bufnr, "filetype", filetype)
	vim.api.nvim_buf_set_option(bufnr, "swapfile", false)

	-- 创建窗口
	local win = vim.api.nvim_open_win(bufnr, false, {
		relative = "cursor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " " .. filename .. " ",
		title_pos = "center",
		focusable = true,
		zindex = DEFAULT_CONFIG.code_zindex,
	})

	-- 设置窗口选项
	vim.api.nvim_win_set_option(win, "wrap", false) -- 禁止自动换行
	vim.api.nvim_win_set_option(win, "linebreak", false)
	vim.api.nvim_win_set_option(win, "number", false)
	vim.api.nvim_win_set_option(win, "relativenumber", false)
	vim.api.nvim_win_set_option(win, "cursorline", false)

	-- 高亮当前代码行
	local target_line = link.line
	local preview_line = target_line - start_line + 1
	if preview_line >= 1 and preview_line <= #context_lines then
		highlight_key_line(bufnr, preview_line, "CodePreviewHighlight", #context_lines)
	end

	-- 保存当前预览窗口信息
	current_preview.win = win
	current_preview.buf = bufnr
	current_preview.type = "code"

	-- 设置监听
	setup_win_close_listener(win, bufnr)
	setup_cursor_listener()
end

---------------------------------------------------------------------
-- 手动关闭预览窗口
---------------------------------------------------------------------
function M.close_preview()
	close_preview_window()
end

---------------------------------------------------------------------
-- 初始化模块
---------------------------------------------------------------------
function M.setup(config)
	-- 合并用户配置
	if config then
		for k, v in pairs(config) do
			if DEFAULT_CONFIG[k] ~= nil then
				DEFAULT_CONFIG[k] = v
			end
		end
	end

	-- 设置高亮组
	ensure_highlight_groups()
end

return M
