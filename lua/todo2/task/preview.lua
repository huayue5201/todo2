-- lua/todo2/link/preview.lua
--- @module todo2.link.preview
--- @brief 预览 TODO 或代码（完整任务树，不受 context_split 影响）
--- @description 支持中文显示优化，使用显示宽度计算窗口大小，修复中文截断问题
--- @version 2.4.0

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local parser = require("todo2.core.parser")
local store_link = require("todo2.store.link")
local id_utils = require("todo2.utils.id")

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
	-- 自动换行配置
	wrap_text = true, -- 是否自动换行（默认true）
	wrap_threshold = 0.9, -- 换行触发阈值：当内容宽度超过窗口宽度的这个比例时触发换行
}

-- 当前预览窗口信息
local current_preview = {
	win = nil,
	buf = nil,
	type = nil, -- 'todo' 或 'code'
	win_close_autocmd = nil, -- 窗口关闭监听ID
	line_mapping = nil, -- 原始行号 → 预览窗口中的行号范围
	target_line = nil, -- 目标行的原始行号
	window_width = nil, -- 当前窗口宽度
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

--- 获取字符串中最长行的显示宽度
--- @param lines table 行列表
--- @return integer 最大显示宽度
local function get_max_line_width(lines)
	local max_width = 0
	for _, line in ipairs(lines) do
		local width = get_display_width(line)
		max_width = math.max(max_width, width)
	end
	return max_width
end

--- 判断是否需要自动换行
--- @param lines table 原始行列表
--- @param window_width integer 窗口宽度
--- @param threshold number 触发阈值
--- @return boolean 是否需要换行
local function should_wrap_lines(lines, window_width, threshold)
	if not DEFAULT_CONFIG.wrap_text then
		return false
	end

	local max_content_width = get_max_line_width(lines)
	local content_width = max_content_width + DEFAULT_CONFIG.border_chars + DEFAULT_CONFIG.safety_margin

	-- 如果内容宽度超过窗口宽度的阈值比例，则需要换行
	return content_width > window_width * threshold
end

--- 文本自动换行函数（返回换行后的行列表）
--- @param text string 原始文本
--- @param max_width integer 每行最大显示宽度
--- @return table 换行后的行列表
local function wrap_text_content(text, max_width)
	if not text or text == "" then
		return { "" }
	end

	-- 确保max_width至少为1
	max_width = math.max(1, max_width)

	local lines = {}
	local current_line = ""
	local current_width = 0

	-- 按字符遍历，而不是按字节
	local i = 1
	while i <= #text do
		-- 获取当前字符及其宽度
		local char = text:sub(i, i)
		local char_byte = char:byte()
		local char_width = 1
		local char_len = 1

		if char_byte and char_byte >= 192 then
			-- 多字节字符，先获取完整字符
			if char_byte >= 192 and char_byte <= 223 then
				char_len = 2
			elseif char_byte >= 224 and char_byte <= 239 then
				char_len = 3
			elseif char_byte >= 240 and char_byte <= 247 then
				char_len = 4
			end

			if i + char_len - 1 <= #text then
				char = text:sub(i, i + char_len - 1)
				char_width = 2 -- 多字节字符通常显示宽度为2
				i = i + char_len
			else
				-- 无效的UTF-8序列，跳过
				i = i + 1
				goto continue
			end
		else
			-- ASCII字符
			i = i + 1
		end

		-- 检查是否需要换行
		if current_width + char_width > max_width then
			-- 当前行已满，保存并开始新行
			table.insert(lines, current_line)
			current_line = char
			current_width = char_width
		else
			current_line = current_line .. char
			current_width = current_width + char_width
		end

		::continue::
	end

	-- 添加最后一行
	if current_line ~= "" then
		table.insert(lines, current_line)
	end

	-- 如果没有内容，返回空行
	if #lines == 0 then
		lines = { "" }
	end

	return lines
end

--- 准备预览内容（支持动态换行）
--- @param original_lines table 原始行列表
--- @param window_width integer 窗口宽度
--- @return table 处理后的行列表
--- @return table 行号映射表 { [原始行号] = { start_line, end_line } }
--- @return boolean 是否进行了换行
local function prepare_preview_content(original_lines, window_width)
	local processed_lines = {}
	local line_mapping = {}
	local current_line_num = 1
	local did_wrap = false

	-- 检查是否需要换行
	local need_wrap = should_wrap_lines(original_lines, window_width, DEFAULT_CONFIG.wrap_threshold)

	if not need_wrap then
		-- 不需要换行时，一一对应
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

	-- 需要换行时，处理每一行
	-- 可用内容宽度 = 窗口宽度 - 边框 - 安全边距
	local available_width = window_width - DEFAULT_CONFIG.border_chars - DEFAULT_CONFIG.safety_margin

	for i, line in ipairs(original_lines) do
		local wrapped_lines = wrap_text_content(line, available_width)

		-- 如果这一行被拆分了，标记为进行了换行
		if #wrapped_lines > 1 then
			did_wrap = true
		end

		line_mapping[i] = {
			original_line = i,
			start_line = current_line_num,
			end_line = current_line_num + #wrapped_lines - 1,
		}

		for _, wrapped_line in ipairs(wrapped_lines) do
			table.insert(processed_lines, wrapped_line)
		end

		current_line_num = current_line_num + #wrapped_lines
	end

	return processed_lines, line_mapping, did_wrap
end

--- 根据原始行号获取预览窗口中的行号范围
--- @param line_mapping table 行号映射表
--- @param original_line integer 原始行号
--- @return integer|nil start_line, integer|nil end_line
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

	-- 清理存储的信息
	current_preview.win = nil
	current_preview.buf = nil
	current_preview.type = nil
	current_preview.win_close_autocmd = nil
	current_preview.line_mapping = nil
	current_preview.target_line = nil
	current_preview.window_width = nil

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
				current_preview.line_mapping = nil
				current_preview.target_line = nil
				current_preview.window_width = nil
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

--- 高亮关键行（支持换行后的多行高亮）
--- @param bufnr integer 缓冲区号
--- @param line_num integer 行号
--- @param highlight_group string 高亮组名
--- @param line_mapping table 行号映射表
--- @param original_line integer 原始行号
local function highlight_key_line(bufnr, line_num, highlight_group, line_mapping, original_line)
	-- 如果没指定高亮组，使用默认值
	highlight_group = highlight_group or "TodoPreviewHighlight"

	-- 确保高亮组存在
	ensure_highlight_groups()

	-- 创建命名空间
	local ns_id = vim.api.nvim_create_namespace("todo_preview_highlight")

	-- 如果有行号映射，获取实际要高亮的行范围
	local start_line, end_line

	if line_mapping and original_line then
		-- 通过映射获取原始行对应的预览行范围
		start_line, end_line = get_preview_line_range(line_mapping, original_line)
	end

	if not start_line or not end_line then
		-- 如果没有映射，就高亮单行
		start_line = line_num
		end_line = line_num
	end

	-- 清除这些行的现有高亮
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, start_line - 1, end_line)

	-- 高亮范围内的每一行
	for line = start_line, end_line do
		-- 添加多个高亮效果组合
		local highlights = { "Underlined", "Search", "Bold", "DiffText", highlight_group }

		for _, hl in ipairs(highlights) do
			pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl, line - 1, 0, -1)
		end

		-- 只为第一行添加左边框标记
		if line == start_line then
			pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, "TodoPreviewLeftMarker", line - 1, 0, 1)
		end
	end
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
-- 创建预览窗口（核心函数）
---------------------------------------------------------------------
--- 创建预览窗口
--- @param lines table 原始行列表
--- @param title string 窗口标题
--- @param filetype string 文件类型
--- @param zindex integer 窗口层级
--- @param target_line_num integer 目标行号（在原始行列表中的索引）
--- @param highlight_group string 高亮组名
--- @return boolean 是否成功
local function create_preview_window(lines, title, filetype, zindex, target_line_num, highlight_group)
	-- 先尝试使用原始内容计算窗口宽度
	local max_content_width = get_max_line_width(lines)
	local border_width = DEFAULT_CONFIG.border_chars
	local min_width = DEFAULT_CONFIG.min_width
	local max_width = DEFAULT_CONFIG.max_width
	local margin = DEFAULT_CONFIG.safety_margin

	-- 计算初始窗口宽度
	local content_chars = math.ceil(max_content_width)
	if content_chars % 2 == 1 then
		content_chars = content_chars + 1
	end

	local initial_width = content_chars + border_width + margin
	initial_width = math.max(initial_width, min_width)
	initial_width = math.min(initial_width, max_width)
	initial_width = math.floor(initial_width)

	-- 准备预览内容（基于初始宽度判断是否需要换行）
	local processed_lines, line_mapping, did_wrap = prepare_preview_content(lines, initial_width)

	-- 如果进行了换行，需要重新计算窗口宽度（基于换行后的最大行宽）
	local final_width = initial_width
	if did_wrap then
		-- 重新计算换行后的最大内容宽度
		local new_max_width = get_max_line_width(processed_lines)
		local new_content_chars = math.ceil(new_max_width)
		if new_content_chars % 2 == 1 then
			new_content_chars = new_content_chars + 1
		end

		final_width = new_content_chars + border_width + margin
		final_width = math.max(final_width, min_width)
		final_width = math.min(final_width, max_width)
		final_width = math.floor(final_width)

		-- 如果宽度变化较大，可能需要重新处理内容
		-- 但为了简化，我们接受这种轻微的宽度变化
	end

	-- 计算高度
	local height = math.min(#processed_lines, DEFAULT_CONFIG.max_height)

	-- 计算窗口位置
	local row, col = calculate_window_position(final_width, height)

	-- 创建浮动预览窗口
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, processed_lines)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(bufnr, "filetype", filetype)
	vim.api.nvim_buf_set_option(bufnr, "swapfile", false)

	-- 创建窗口
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

	-- 设置窗口选项
	vim.api.nvim_win_set_option(win, "wrap", did_wrap) -- 如果已经手动换行，就不需要自动换行
	vim.api.nvim_win_set_option(win, "linebreak", did_wrap)
	vim.api.nvim_win_set_option(win, "number", false)
	vim.api.nvim_win_set_option(win, "relativenumber", false)
	vim.api.nvim_win_set_option(win, "cursorline", false)

	-- 保存预览窗口信息
	current_preview.win = win
	current_preview.buf = bufnr
	current_preview.type = filetype == "markdown" and "todo" or "code"
	current_preview.line_mapping = line_mapping
	current_preview.target_line = target_line_num
	current_preview.window_width = final_width

	-- 高亮目标行
	highlight_key_line(bufnr, target_line_num, highlight_group, line_mapping, target_line_num)

	-- 设置监听
	setup_win_close_listener(win, bufnr)
	setup_cursor_listener()

	return true
end

---------------------------------------------------------------------
-- 预览 TODO（支持自动换行和高亮）
---------------------------------------------------------------------
function M.preview_todo()
	-- 先关闭已有的预览窗口
	close_preview_window()

	local line = vim.fn.getline(".")
	-- 使用 id_utils 提取
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
	local title = " " .. filename .. " "

	-- 计算目标行在预览内容中的位置
	local target_line = current.line_num - min_line + 1

	-- 创建预览窗口
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
-- 预览代码（支持自动换行和高亮）
---------------------------------------------------------------------
function M.preview_code()
	-- 先关闭已有的预览窗口
	close_preview_window()

	local line = vim.fn.getline(".")
	-- 使用 id_utils 提取
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
		table.insert(context_lines, lines[i])
	end

	-- 获取文件类型和文件名
	local filetype = get_filetype(link.path)
	local filename = get_filename(link.path)
	local title = " " .. filename .. " "

	-- 目标行在上下文中的位置
	local target_line = link.line - start_line + 1

	-- 创建预览窗口
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
-- 手动关闭预览窗口
---------------------------------------------------------------------
function M.close_preview()
	close_preview_window()
end

---------------------------------------------------------------------
-- 初始化模块（支持配置自动换行）
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
