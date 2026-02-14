-- lua/todo2/utils/line_analyzer.lua
local M = {}

local format = require("todo2.utils.format")

--- 行分析结果
--- @class LineAnalysis
--- @field is_todo_task boolean 是否是TODO任务行
--- @field is_code_mark boolean 是否是代码标记行
--- @field is_todo_mark boolean 是否是TODO标记行
--- @field is_mark boolean 是否是任意标记行
--- @field id string|nil 标记ID
--- @field tag string|nil 标签
--- @field status string|nil 任务状态
--- @field content string|nil 内容
--- @field line string 原始行内容
--- @field bufnr number 缓冲区号
--- @field lnum number 行号

--- 分析单行
--- @param bufnr number 缓冲区号
--- @param lnum number 行号
--- @return LineAnalysis
function M.analyze_line(bufnr, lnum)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local is_todo_file = filename:match("%.todo%.md$") ~= nil

	local result = {
		is_todo_task = false,
		is_code_mark = false,
		is_todo_mark = false,
		is_mark = false,
		id = nil,
		tag = nil,
		status = nil,
		content = nil,
		line = line,
		bufnr = bufnr,
		lnum = lnum,
	}

	-- 检查TODO任务行
	if is_todo_file and format.is_task_line(line) then
		result.is_todo_task = true
		local parsed = format.parse_task_line(line)
		if parsed then
			result.id = parsed.id
			result.tag = parsed.tag
			result.status = parsed.status
			result.content = parsed.content
		end
	end

	-- 检查TODO标记行
	local todo_mark_id = line:match("{#(%w+)}")
	if todo_mark_id then
		result.is_todo_mark = true
		result.is_mark = true
		result.id = todo_mark_id
	end

	-- 检查代码标记行
	local code_tag, code_id = line:match("%s*(%u+):ref:(%w+)")
	if code_id then
		result.is_code_mark = true
		result.is_mark = true
		result.id = code_id
		result.tag = code_tag
	end

	return result
end

--- 分析当前行
--- @return LineAnalysis
function M.analyze_current_line()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	return M.analyze_line(bufnr, lnum)
end

--- 分析多行
--- @param bufnr number 缓冲区号
--- @param start_lnum number 起始行号
--- @param end_lnum number 结束行号
--- @return table
function M.analyze_lines(bufnr, start_lnum, end_lnum)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)
	local results = {
		has_markers = false,
		ids = {},
		analyses = {},
	}

	for i, _ in ipairs(lines) do
		local lnum = start_lnum + i - 1
		local analysis = M.analyze_line(bufnr, lnum)
		table.insert(results.analyses, analysis)

		if analysis.is_mark then
			results.has_markers = true
			if analysis.id then
				table.insert(results.ids, analysis.id)
			end
		end
	end

	return results
end

return M
