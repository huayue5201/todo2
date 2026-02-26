-- lua/todo2/link/utils.lua
local M = {}

---------------------------------------------------------------------
-- 依赖
---------------------------------------------------------------------
local comment = require("todo2.utils.comment")

---------------------------------------------------------------------
function M.find_task_insert_position(lines)
	for i, line in ipairs(lines) do
		if line:match("^%s*[-*]%s+%[[ xX]%]") then
			return i
		end
	end

	for i, line in ipairs(lines) do
		if line:match("^#+ ") then
			for j = i + 1, #lines do
				if lines[j] == "" then
					return j + 1
				end
			end
			return i + 1
		end
	end

	return 1
end

---------------------------------------------------------------------
-- 获取指定行的缩进
--- @param bufnr number 缓冲区编号
--- @param line_num number 行号
--- @return string 缩进字符串
function M.get_line_indent(bufnr, line_num)
	local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
	if not line then
		return ""
	end

	-- 匹配开头的空白字符（空格和制表符）
	local indent = line:match("^(%s*)")
	return indent or ""
end

---------------------------------------------------------------------
-- 统一：在代码 buffer 中将 TODO 标记插入到"上一行"（带缩进）
--- @param bufnr number 代码缓冲区
--- @param row number 代码行号
--- @param id string 任务ID
--- @param tag string 标签
--- @param opts? table 选项
---   - preserve_indent: boolean 是否保留原行缩进（默认true）
---   - additional_indent: string 额外缩进（可选）
--- @return boolean 是否成功
function M.insert_code_tag_above(bufnr, row, id, tag, opts)
	opts = opts or {}

	-- 使用 comment 模块生成标记行基础内容
	tag = tag or "TODO"
	local marker = comment.generate_marker(id, tag, bufnr) -- 返回带注释前缀的标记

	-- 获取缩进
	local indent = ""
	if opts.preserve_indent ~= false then
		indent = M.get_line_indent(bufnr, row)
	end

	-- 添加额外缩进
	if opts.additional_indent then
		indent = indent .. opts.additional_indent
	end

	-- 组合最终标记行（缩进 + 标记）
	local tag_line = indent .. marker

	-- 在 row-1 的位置插入新行（上一行）
	local success, err = pcall(vim.api.nvim_buf_set_lines, bufnr, row - 1, row - 1, false, { tag_line })
	if not success then
		vim.notify("插入代码标记失败: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end

	return true
end

---------------------------------------------------------------------
-- 检查是否在 TODO 浮动窗口中
---------------------------------------------------------------------
function M.is_todo_floating_window(win_id)
	win_id = win_id or vim.api.nvim_get_current_win()

	if not vim.api.nvim_win_is_valid(win_id) then
		return false
	end

	local win_config = vim.api.nvim_win_get_config(win_id)
	local is_float = win_config.relative ~= ""

	if not is_float then
		return false
	end

	-- 检查buffer是否是TODO文件
	local bufnr = vim.api.nvim_win_get_buf(win_id)
	local bufname = vim.api.nvim_buf_get_name(bufnr)

	return bufname:match("%.todo%.md$") or bufname:match("todo")
end

return M
