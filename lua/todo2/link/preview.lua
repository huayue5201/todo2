-- lua/todo2/link/preview.lua
--- @module todo2.link.preview
--- @brief 预览 TODO 或代码（完整任务树，不受 context_split 影响）

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local parser = require("todo2.core.parser")
local store_link = require("todo2.store.link")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------
-- TODO:ref:6e34b1
local TODO_REF_PATTERN = "(%u+):ref:(%w+)"
local CODE_ANCHOR_PATTERN = "{#(%w+)}"

-- 当前预览窗口ID和类型
local current_preview = {
	win = nil,
	buf = nil,
	type = nil, -- 'todo' 或 'code'
}
-- 光标位置监听ID
local cursor_autocmd_id = nil

---------------------------------------------------------------------
-- 工具函数：关闭预览窗口
---------------------------------------------------------------------
local function close_preview_window()
	if current_preview.win and vim.api.nvim_win_is_valid(current_preview.win) then
		pcall(vim.api.nvim_win_close, current_preview.win, true)
		current_preview.win = nil
		current_preview.buf = nil
		current_preview.type = nil
	end

	-- 清除光标监听
	if cursor_autocmd_id then
		pcall(vim.api.nvim_del_autocmd, cursor_autocmd_id)
		cursor_autocmd_id = nil
	end
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
-- 工具函数：高亮关键行（增强版）- 只有当内容超过一行时才高亮
---------------------------------------------------------------------
local function highlight_key_line(bufnr, line_num, highlight_group, total_lines)
	-- 如果预览内容只有一行，不高亮
	if total_lines and total_lines <= 1 then
		return
	end

	-- 如果没指定高亮组，使用默认值
	highlight_group = highlight_group or "TodoPreviewHighlight"

	-- 创建命名空间
	local ns_id = vim.api.nvim_create_namespace("todo_preview_highlight")

	-- 清除该行的现有高亮
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, line_num - 1, line_num)

	-- 添加多个高亮效果组合，确保视觉突出
	-- 1. 下划线
	vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Underlined", line_num - 1, 0, -1)

	-- 2. 背景色（使用不同的高亮组）
	vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Search", line_num - 1, 0, -1)

	-- 3. 加粗（如果支持）
	pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, "Bold", line_num - 1, 0, -1)

	-- 4. 添加一个额外的视觉标记（行号背景或特殊颜色）
	pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, "DiffText", line_num - 1, 0, -1)

	-- 可选：添加左边框标记（如果支持）
	pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, "TodoPreviewLeftMarker", line_num - 1, 0, 1)
end

---------------------------------------------------------------------
-- 获取文件类型（使用 Neovim 内置函数）- 修复版本
---------------------------------------------------------------------
--- 根据文件路径获取文件类型
--- @param path string 文件路径
--- @return string 文件类型
local function get_filetype(path)
	-- 直接从文件名获取文件类型（对于大多数情况已经足够）
	local ft = vim.filetype.match({ filename = path })

	-- 如果文件名匹配失败，尝试通过文件内容匹配
	if not ft then
		-- 创建一个临时缓冲区但不设置名称
		local bufnr = vim.api.nvim_create_buf(false, true)

		-- 读取文件前几行来帮助检测类型
		local lines = {}
		local file = io.open(path, "r")
		if file then
			-- 只读取前5行就够了
			for i = 1, 5 do
				local line = file:read()
				if not line then
					break
				end
				table.insert(lines, line)
			end
			file:close()

			-- 如果有读取到内容，设置缓冲区内容
			if #lines > 0 then
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
			end
		end

		-- 基于缓冲区内容检测文件类型
		ft = vim.filetype.match({ buf = bufnr })

		-- 立即删除临时缓冲区
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end

	return ft or "text"
end

---------------------------------------------------------------------
-- 获取文件名（从路径中）
---------------------------------------------------------------------
--- 从文件路径中获取文件名
--- @param path string 文件路径
--- @return string 文件名
local function get_filename(path)
	return path:match("([^/]+)$") or path
end

---------------------------------------------------------------------
-- 预览 TODO（始终使用完整任务树）
---------------------------------------------------------------------
function M.preview_todo()
	-- 先关闭已有的预览窗口
	close_preview_window()

	local line = vim.fn.getline(".")
	local tag, id = line:match(TODO_REF_PATTERN)
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
	local ok, lines = pcall(vim.fn.readfile, todo_path)
	if not ok then
		vim.notify("无法读取文件: " .. todo_path, vim.log.levels.ERROR)
		return
	end

	-- 使用完整树解析，确保能定位任何任务（无论是否归档）
	local _, _, id_to_task = parser.parse_file(todo_path)
	local current = id_to_task and id_to_task[id]
	if not current then
		vim.notify("任务树中未找到 ID 为 " .. id .. " 的任务", vim.log.levels.WARN)
		return
	end

	-- 找到根任务（展示整个父任务子树）
	-- TODO:ref:ab6c9f
	local root = current
	while root.parent do
		root = root.parent
	end

	-- 收集整个子树的所有任务
	local all = {}
	local function collect(t)
		table.insert(all, t)
		for _, c in ipairs(t.children or {}) do
			collect(c)
		end
	end
	collect(root)

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

	-- 创建浮动预览窗口
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, preview_lines)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")

	-- 计算窗口大小
	local width = 80
	local height = math.min(#preview_lines, 30)

	-- 检查最长行
	local max_line_len = 0
	for _, line in ipairs(preview_lines) do
		max_line_len = math.max(max_line_len, #line)
	end
	width = math.min(math.max(width, max_line_len + 4), 120)

	-- 创建浮动窗口，使用较高的zindex确保置顶
	local win = vim.api.nvim_open_win(bufnr, false, {
		relative = "cursor",
		width = width,
		height = height,
		row = 1,
		col = 0,
		style = "minimal",
		border = "rounded",
		title = filename,
		title_pos = "center",
		focusable = true,
		zindex = 100, -- TODO预览窗口层级
	})

	-- 设置窗口选项
	vim.api.nvim_win_set_option(win, "wrap", true)
	vim.api.nvim_win_set_option(win, "linebreak", true)

	-- 高亮当前任务行（增强版）- 只有当内容超过一行时才高亮
	local target_line = current.line_num
	local preview_line = target_line - min_line + 1
	if preview_line >= 1 and preview_line <= #preview_lines then
		highlight_key_line(bufnr, preview_line, "TodoPreviewHighlight", #preview_lines)
	end

	-- 保存当前预览窗口信息
	current_preview.win = win
	current_preview.buf = bufnr
	current_preview.type = "todo"

	-- 设置光标监听
	setup_cursor_listener()
end

---------------------------------------------------------------------
-- 预览代码（使用 Neovim 内置文件类型检测）
---------------------------------------------------------------------
function M.preview_code()
	-- 先关闭已有的预览窗口
	close_preview_window()

	local line = vim.fn.getline(".")
	local id = line:match(CODE_ANCHOR_PATTERN)
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

	local ok, lines = pcall(vim.fn.readfile, link.path)
	if not ok then
		vim.notify("无法读取文件: " .. link.path, vim.log.levels.ERROR)
		return
	end

	local start_line = math.max(1, link.line - 3)
	local end_line = math.min(#lines, link.line + 3)
	local context_lines = {}

	for i = start_line, end_line do
		context_lines[#context_lines + 1] = lines[i]
	end

	-- 使用 Neovim 内置的文件类型检测
	local filetype = get_filetype(link.path)

	-- 获取文件名作为标题
	local filename = get_filename(link.path)

	-- 创建浮动预览窗口
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, context_lines)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(bufnr, "filetype", filetype)

	-- 计算窗口大小
	local width = 80
	local height = math.min(#context_lines, 30)

	-- 检查最长行
	local max_line_len = 0
	for _, line in ipairs(context_lines) do
		max_line_len = math.max(max_line_len, #line)
	end
	width = math.min(math.max(width, max_line_len + 4), 120)

	-- 创建浮动窗口，使用更高的zindex确保不会被TODO窗口遮蔽
	local win = vim.api.nvim_open_win(bufnr, false, {
		relative = "cursor",
		width = width,
		height = height,
		row = 1,
		col = 0,
		style = "minimal",
		border = "rounded",
		title = " " .. filename .. " ",
		title_pos = "center",
		focusable = true,
		zindex = 200, -- 代码预览窗口层级（更高，确保不会被TODO窗口遮蔽）
	})

	-- 设置窗口选项
	vim.api.nvim_win_set_option(win, "wrap", true)
	vim.api.nvim_win_set_option(win, "linebreak", true)

	-- 高亮当前代码行（增强版）- 只有当内容超过一行时才高亮
	local target_line = link.line
	local preview_line = target_line - start_line + 1
	if preview_line >= 1 and preview_line <= #context_lines then
		highlight_key_line(bufnr, preview_line, "CodePreviewHighlight", #context_lines)
	end

	-- 保存当前预览窗口信息
	current_preview.win = win
	current_preview.buf = bufnr
	current_preview.type = "code"

	-- 设置光标监听
	setup_cursor_listener()
end

---------------------------------------------------------------------
-- 手动关闭预览窗口
---------------------------------------------------------------------
function M.close_preview()
	close_preview_window()
end

-- 可选：定义高亮组（可以在插件初始化时调用）
function M.setup_highlights()
	vim.cmd([[
		highlight default TodoPreviewHighlight guibg=#3a3a3a guifg=NONE gui=underline,bold
		highlight default CodePreviewHighlight guibg=#2a4a2a guifg=NONE gui=underline,bold
		highlight default TodoPreviewLeftMarker guibg=#ffaa00 guifg=#000000
	]])
end

return M
