-- lua/todo2/utils/format.lua
-- 最终版：完全依赖 id_utils，只支持新格式 TAG:ref:ID

local M = {}

local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------

---@class FormatConfig
---@field checkbox table
---@field task_start string
---@field EMPTY_LINE_MARKER string
---@field NORMAL_LINE_MARKER string

---@type FormatConfig
M.config = {
	checkbox = {
		todo = "[ ]",
		done = "[x]",
		archived = "[>]",
		pattern = "%[[ xX>]%]",
		pattern_todo = "%[ %]",
		pattern_done = "%[[xX]%]",
	},
	task_start = "^%s*[-*+]%s+",
	EMPTY_LINE_MARKER = "__EMPTY_LINE__",
	NORMAL_LINE_MARKER = "__NORMAL_LINE__",
}

---------------------------------------------------------------------
-- 代码行规范化（用于上下文指纹）
---------------------------------------------------------------------

--- 规范化代码行（用于上下文指纹）
---@param line string
---@param options? { keep_indent?: boolean }
---@return string normalized
function M.normalize_code_line(line, options)
	options = options or {}
	if not line then
		return ""
	end

	if line:match("^%s*$") then
		return options.keep_indent and line or M.config.EMPTY_LINE_MARKER
	end

	local normalized = line

	-- 去除注释
	if normalized:match("^%s*%-%-") then
		normalized = normalized:gsub("%-%-.*$", "--")
	elseif normalized:match("^%s*//") then
		normalized = normalized:gsub("//.*$", "//")
	elseif normalized:match("^%s*#") then
		normalized = normalized:gsub("#.*$", "#")
	else
		normalized = normalized:gsub("%-%-.*$", "")
		normalized = normalized:gsub("//.*$", "")
		normalized = normalized:gsub("#.*$", "")
	end

	-- 去除多余空白
	normalized = normalized:gsub("^%s+", "")
	normalized = normalized:gsub("%s+$", "")
	normalized = normalized:gsub("%s+", " ")

	if options.keep_indent then
		local indent = line:match("^(%s*)") or ""
		normalized = indent .. normalized
	end

	if normalized == "" then
		normalized = M.config.NORMAL_LINE_MARKER
	end

	return normalized
end

---------------------------------------------------------------------
-- 判断/提取
---------------------------------------------------------------------

--- 判断是否为 TODO 任务行
---@param line string
---@return boolean
function M.is_task_line(line)
	if not line then
		return false
	end
	return line:match(M.config.task_start .. M.config.checkbox.pattern) ~= nil
end

--- 提取所有 ID（只提取第一个）
---@param line string
---@return string[]
function M.extract_all_ids(line)
	if not line or line == "" then
		return {}
	end
	local ids = {}
	local id = id_utils.extract_id(line)
	if id then
		table.insert(ids, id)
	end
	return ids
end

--- 从当前行提取 ID
---@param bufnr number?
---@return string[]
function M.extract_ids_from_current_line(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local line_num = cursor[1]
	local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1] or ""
	return M.extract_all_ids(line)
end

--- 提取标签（从 TAG:ref:ID）
---@param content string
---@return string tag
function M.extract_tag(content)
	if not content then
		return "TODO"
	end
	return id_utils.extract_tag_from_code_mark(content) or "TODO"
end

--- 从代码行提取 tag 和 id
---@param code_line string
---@return string tag, string|nil id
function M.extract_from_code_line(code_line)
	if not code_line then
		return "TODO", nil
	end
	local tag = id_utils.extract_tag_from_code_mark(code_line)
	local id = id_utils.extract_id_from_code_mark(code_line)
	return tag or "TODO", id
end

---------------------------------------------------------------------
-- 位置计算
---------------------------------------------------------------------

--- 获取 checkbox 的位置
---@param line string
---@return number|nil start, number|nil end_
function M.get_checkbox_position(line)
	if not line then
		return nil, nil
	end
	return line:find(M.config.checkbox.pattern)
end

--- 获取 ID 的位置
---@param line string
---@return number|nil start, number|nil end_
function M.get_id_position(line)
	if not line then
		return nil, nil
	end
	return id_utils.find_id_position(line)
end

---------------------------------------------------------------------
-- ⭐ 格式化任务行（写入）
---------------------------------------------------------------------

--- 格式化任务行（写入 TODO 文件）
---@param options { indent?: string, checkbox?: string, id?: string, tag?: string, content?: string }
---@return string line
function M.format_task_line(options)
	local opts = vim.tbl_extend("force", {
		indent = "",
		checkbox = "[ ]",
		id = nil,
		tag = "TODO",
		content = "",
	}, options or {})

	local parts = { opts.indent, "- ", opts.checkbox }

	if opts.tag and opts.id then
		table.insert(parts, " " .. id_utils.format_mark(opts.tag, opts.id))
	end

	if opts.content and opts.content ~= "" then
		table.insert(parts, " " .. opts.content)
	end

	return table.concat(parts, "")
end

---------------------------------------------------------------------
-- ⭐ 解析任务行（读取）
---------------------------------------------------------------------

--- 解析 TODO 任务行
---@param line string
---@param opts? { context_fingerprint?: string }
---@return table|nil parsed
function M.parse_task_line(line, opts)
	opts = opts or {}
	if not line then
		return nil
	end

	-- 缩进
	local indent = line:match("^(%s*)") or ""

	-- checkbox
	local checkbox_match = line:match("^%s*[-*+]%s+(%[[ xX>]%])")
	if not checkbox_match then
		return nil
	end

	-- 剩余部分
	local rest = line:match("^%s*[-*+]%s+%[[ xX>]%]%s*(.*)$") or ""

	-- 提取 TAG:ref:ID
	local tag, id = M.extract_from_code_line(rest)

	-- 移除 TAG:ref:ID
	if tag and id then
		local mark = id_utils.format_mark(tag, id)
		rest = rest:gsub(vim.pesc(mark), "")
	end

	-- content 永远纯文本
	local content = vim.trim(rest)

	-- 状态
	local status
	if checkbox_match == "[>]" then
		status = "archived"
	elseif checkbox_match:match("%[[xX]%]") then
		status = "completed"
	else
		status = "normal"
	end

	return {
		indent = indent,
		level = #indent / 2,
		checkbox = checkbox_match,
		status = status,
		id = id,
		tag = tag or "TODO",
		content = content,
		children = {},
		parent = nil,
		context_fingerprint = opts.context_fingerprint,
	}
end

---------------------------------------------------------------------
-- 提取上下文
---------------------------------------------------------------------

--- 提取任务上下文（轻量版）
---@param line string
---@return table|nil
function M.extract_task_context(line)
	if not line then
		return nil
	end

	local parsed = M.parse_task_line(line)
	if not parsed then
		return nil
	end

	return {
		id = parsed.id,
		tag = parsed.tag,
		status = parsed.status,
		content = parsed.content,
		indent = parsed.indent,
		level = parsed.level,
	}
end

return M
