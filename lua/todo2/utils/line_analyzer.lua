-- lua/todo2/utils/line_analyzer.lua
-- 最终版：仅支持新格式 TAG:ref:ID，严格 LuaDoc

local M = {}

local format = require("todo2.utils.format")
local id_utils = require("todo2.utils.id")

---@class LineAnalysis
---@field is_todo_task boolean 是否是 TODO 文件中的任务行
---@field is_code_mark boolean 是否是代码中的标记行（TAG:ref:ID）
---@field is_mark boolean 是否是任意标记行
---@field id string|nil 解析到的任务 ID
---@field tag string|nil 解析到的标签
---@field status string|nil 任务状态（normal/completed/archived）
---@field content string|nil 任务内容（纯文本）
---@field line string 原始行内容
---@field bufnr number 缓冲区号
---@field lnum number 行号

--- 分析单行内容
---@param bufnr number 缓冲区号
---@param lnum number 行号（1-based）
---@return LineAnalysis
function M.analyze_line(bufnr, lnum)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local is_todo_file = filename:match("%.todo%.md$") ~= nil

	---@type LineAnalysis
	local result = {
		is_todo_task = false,
		is_code_mark = false,
		is_mark = false,
		id = nil,
		tag = nil,
		status = nil,
		content = nil,
		line = line,
		bufnr = bufnr,
		lnum = lnum,
	}

	----------------------------------------------------------------------
	-- 1. TODO 文件中的任务行
	----------------------------------------------------------------------
	if is_todo_file and format.is_task_line(line) then
		result.is_todo_task = true
		local parsed = format.parse_task_line(line)
		if parsed then
			result.id = parsed.id
			result.tag = parsed.tag
			result.status = parsed.status
			result.content = parsed.content
			result.is_mark = parsed.id ~= nil
		end
	end

	----------------------------------------------------------------------
	-- 2. 代码标记行（TAG:ref:ID）
	----------------------------------------------------------------------
	if id_utils.contains_code_mark(line) then
		result.is_code_mark = true
		result.is_mark = true
		result.id = id_utils.extract_id_from_code_mark(line)
		result.tag = id_utils.extract_tag_from_code_mark(line)
	end

	return result
end

--- 分析当前行
---@return LineAnalysis
function M.analyze_current_line()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	return M.analyze_line(bufnr, lnum)
end

--- 分析多行
---@param bufnr number 缓冲区号
---@param start_lnum number 起始行号（1-based）
---@param end_lnum number 结束行号（1-based）
---@return { has_markers: boolean, ids: string[], analyses: LineAnalysis[] }
function M.analyze_lines(bufnr, start_lnum, end_lnum)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)

	local results = {
		has_markers = false,
		ids = {},
		analyses = {},
	}

	for i = 1, #lines do
		local lnum = start_lnum + i - 1
		local analysis = M.analyze_line(bufnr, lnum)
		table.insert(results.analyses, analysis)

		if analysis.is_mark and analysis.id then
			results.has_markers = true
			table.insert(results.ids, analysis.id)
		end
	end

	return results
end

----------------------------------------------------------------------
-- 缓存版本（性能优化）
----------------------------------------------------------------------

local line_cache = {}
local cache_max_size = 100

--- 带缓存的行分析
---@param bufnr number
---@param lnum number
---@param use_cache boolean 是否启用缓存
---@return LineAnalysis
function M.analyze_line_cached(bufnr, lnum, use_cache)
	if not use_cache then
		return M.analyze_line(bufnr, lnum)
	end

	local cache_key = string.format("%d:%d", bufnr, lnum)

	if line_cache[cache_key] then
		return line_cache[cache_key]
	end

	local result = M.analyze_line(bufnr, lnum)

	-- 缓存大小控制
	if next(line_cache) and #line_cache >= cache_max_size then
		line_cache = {}
	end

	line_cache[cache_key] = result
	return result
end

return M
