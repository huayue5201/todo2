-- lua/todo2/utils/line_analyzer.lua
-- 行内容分析器：识别TODO任务行和代码标记行

local M = {}

local format = require("todo2.utils.format")
local id_utils = require("todo2.utils.id")

---@class LineAnalysis
---@field is_todo_task boolean
---@field is_code_mark boolean
---@field is_mark boolean
---@field id string|nil
---@field tag string|nil
---@field status string|nil
---@field content string|nil
---@field line string
---@field bufnr number
---@field lnum number

-- 缓存
local cache = {}
local cache_max = 100

---分析单行
---@param bufnr number
---@param lnum number
---@return LineAnalysis
function M.analyze_line(bufnr, lnum)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local is_todo = filename:match("%.todo%.md$") ~= nil

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

	-- TODO文件任务行
	if is_todo and format.is_task_line(line) then
		result.is_todo_task = true
		local parsed = format.parse_task_line(line)
		if parsed then
			result.id = parsed.id
			result.tag = parsed.tag
			result.status = parsed.status
			result.content = parsed.content
			result.is_mark = parsed.id ~= nil
		end
		return result
	end

	-- 代码标记行 TAG:ref:ID
	if id_utils.contains_code_mark(line) then
		local id = id_utils.extract_id_from_code_mark(line)
		local tag = id_utils.extract_tag_from_code_mark(line)
		if id and tag and id_utils.is_valid(id) then
			result.is_code_mark = true
			result.is_mark = true
			result.id = id
			result.tag = tag
		end
	end

	return result
end

---分析当前行
---@return LineAnalysis
function M.analyze_current_line()
	return M.analyze_line(vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

---分析多行
---@param bufnr number
---@param start_lnum number
---@param end_lnum number
---@return {has_markers: boolean, ids: string[], analyses: LineAnalysis[]}
function M.analyze_lines(bufnr, start_lnum, end_lnum)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)
	local results = { has_markers = false, ids = {}, analyses = {} }

	for i = 1, #lines do
		local analysis = M.analyze_line(bufnr, start_lnum + i - 1)
		table.insert(results.analyses, analysis)
		if analysis.is_mark and analysis.id then
			results.has_markers = true
			table.insert(results.ids, analysis.id)
		end
	end

	return results
end

---带缓存的分析
---@param bufnr number
---@param lnum number
---@return LineAnalysis
function M.analyze_line_cached(bufnr, lnum)
	local key = string.format("%d:%d", bufnr, lnum)

	if cache[key] then
		return cache[key]
	end

	local result = M.analyze_line(bufnr, lnum)

	-- 缓存大小控制（正确统计hash table大小）
	local count = 0
	for _ in pairs(cache) do
		count = count + 1
		if count >= cache_max then
			cache = {}
			break
		end
	end

	cache[key] = result
	return result
end

-- 自动清理缓存（文件变化时清理相关缓冲区的缓存）
vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged", "BufDelete" }, {
	callback = function(ev)
		local prefix = string.format("%d:", ev.buf)
		for key in pairs(cache) do
			if key:find(prefix, 1, true) == 1 then
				cache[key] = nil
			end
		end
	end,
})

return M
