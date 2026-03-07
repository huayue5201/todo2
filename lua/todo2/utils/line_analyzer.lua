-- lua/todo2/utils/line_analyzer.lua
-- 精简版 - 删除重复的ID/标签检测逻辑

local M = {}

local format = require("todo2.utils.format")
local id_utils = require("todo2.utils.id")

--- @class LineAnalysis
--- @field is_todo_task boolean 是否是TODO任务行
--- @field is_code_mark boolean 是否是代码标记行
--- @field is_todo_mark boolean 是否是TODO标记行
--- @field is_mark boolean 是否是任意标记行
--- @field id string|nil 标记ID
--- @field tag string|nil 标签
--- @field status string|nil 任务状态
--- @field content string|nil 内容
--- @field context_valid boolean|nil 上下文是否有效
--- @field context_similarity number|nil 上下文相似度
--- @field line string 原始行内容
--- @field bufnr number 缓冲区号
--- @field lnum number 行号

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
		context_valid = nil,
		context_similarity = nil,
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

			-- 从存储获取上下文信息
			if parsed.id then
				local store = require("todo2.store.link")
				local link = store.get_todo(parsed.id, { verify_line = false })
				if link and link.context then
					result.context_valid = link.context_valid
					result.context_similarity = link.context_similarity
				end
			end
		end
	end

	-- ✅ 检查TODO锚点（直接用id_utils）
	if id_utils.contains_todo_anchor(line) then
		result.is_todo_mark = true
		result.is_mark = true
		result.id = id_utils.extract_id_from_todo_anchor(line)
	end

	-- ✅ 检查代码标记（直接用id_utils）
	if id_utils.contains_code_mark(line) then
		result.is_code_mark = true
		result.is_mark = true
		result.id = id_utils.extract_id_from_code_mark(line)
		result.tag = id_utils.extract_tag_from_code_mark(line)

		-- 从存储获取上下文信息
		if result.id then
			local store = require("todo2.store.link")
			local link = store.get_code(result.id, { verify_line = false })
			if link and link.context then
				result.context_valid = link.context_valid
				result.context_similarity = link.context_similarity
			end
		end
	end

	return result
end

function M.analyze_current_line()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	return M.analyze_line(bufnr, lnum)
end

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

--- 带缓存的行分析（性能优化）
local line_cache = {}
local cache_max_size = 100

function M.analyze_line_cached(bufnr, lnum, use_cache)
	use_cache = use_cache ~= false

	local cache_key = string.format("%d:%d", bufnr, lnum)

	if use_cache and line_cache[cache_key] then
		return line_cache[cache_key]
	end

	local result = M.analyze_line(bufnr, lnum)

	if use_cache then
		if vim.tbl_count(line_cache) >= cache_max_size then
			line_cache = {}
		end
		line_cache[cache_key] = result
	end

	return result
end

function M.clear_cache()
	line_cache = {}
end

function M.invalidate_buffer_cache(bufnr)
	for key, _ in pairs(line_cache) do
		if key:match("^" .. bufnr .. ":") then
			line_cache[key] = nil
		end
	end
end

return M
