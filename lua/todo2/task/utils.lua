-- lua/todo2/task/utils.lua
-- 任务工具模块：处理代码标记插入、缩进等
---@module "todo2.task.utils"

local M = {}

---------------------------------------------------------------------
-- 依赖
---------------------------------------------------------------------
local comment = require("todo2.utils.comment")

---------------------------------------------------------------------
-- 查找任务插入位置
---@param lines string[] 文件行
---@return number 插入位置的行号
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
-- 获取指定行的缩进（增强版：空行时自动向上查找）
---@param bufnr number 缓冲区编号
---@param line_num number 行号
---@param opts? { fallback?: boolean } 选项，fallback=true时空行向上查找
---@return string 缩进字符串
function M.get_line_indent(bufnr, line_num, opts)
	opts = opts or { fallback = true }

	local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
	if not line then
		return ""
	end

	-- 匹配开头的空白字符（空格和制表符）
	local indent = line:match("^(%s*)") or ""

	-- 如果当前行是空行且启用了fallback，向上查找最近的非空行
	if opts.fallback and line:match("^%s*$") then
		for i = line_num - 1, 1, -1 do
			local prev_line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
			if not prev_line:match("^%s*$") then
				indent = prev_line:match("^(%s*)") or ""
				break
			end
		end
	end

	return indent
end

---------------------------------------------------------------------
-- 统一：在代码 buffer 中将 TODO 标记插入到"上一行"（带缩进）
---@param bufnr number 代码缓冲区
---@param row number 代码行号
---@param id string 任务ID
---@param tag string 标签
---@param opts? table 选项
---   - preserve_indent: boolean 是否保留原行缩进（默认true）
---   - additional_indent: string 额外缩进（可选）
---@return boolean 是否成功
-- FIX:ref:e2ce75
function M.insert_code_tag_above(bufnr, row, id, tag, opts)
	opts = opts or {}

	-- 验证参数
	if not bufnr or not row or not id then
		vim.notify("插入代码标记失败：缺少必要参数", vim.log.levels.ERROR)
		return false
	end

	-- 使用 comment 模块生成标记行基础内容
	tag = tag or "TODO"
	local marker = comment.generate_marker(id, tag, bufnr) -- 返回带注释前缀的标记

	-- 获取缩进（使用增强版，自动处理空行）
	local indent = ""
	if opts.preserve_indent ~= false then
		indent = M.get_line_indent(bufnr, row, { fallback = true })
	end

	-- 添加额外缩进
	if opts.additional_indent then
		indent = indent .. opts.additional_indent
	end

	-- 组合最终标记行（缩进 + 标记）
	local tag_line = indent .. marker

	-- 调试信息（仅在debug模式）
	if vim.g.todo2_debug then
		print(
			string.format(
				"插入代码标记: 行=%d, 缩进='%s'(%d), 标记='%s'",
				row,
				indent:gsub(" ", "·"),
				#indent,
				tag_line
			)
		)
	end

	-- 在 row-1 的位置插入新行（上一行）
	local success, err = pcall(vim.api.nvim_buf_set_lines, bufnr, row - 1, row - 1, false, { tag_line })
	if not success then
		vim.notify("插入代码标记失败: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end

	-- 处理行号偏移
	local store_line = require("todo2.store.link.line")
	if store_line and store_line.link and store_line.link.handle_line_shift then
		store_line.link.handle_line_shift(bufnr, row, 1)
	end

	return true
end

---------------------------------------------------------------------
-- 检查是否在 TODO 浮动窗口中
---@param win_id? number 窗口ID，默认当前窗口
---@return boolean
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
