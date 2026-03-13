-- lua/todo2/utils/format.lua
-- 精简版：完全依赖 id_utils，移除所有备用解析逻辑

local M = {}

local id_utils = require("todo2.utils.id")

-- 格式配置中心
---------------------------------------------------------------------
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

function M.normalize_code_line(line, options)
	options = options or {}
	if not line then
		return ""
	end

	if line:match("^%s*$") then
		return options.keep_indent and line or M.config.EMPTY_LINE_MARKER
	end

	local normalized = line

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

function M.is_task_line(line)
	if not line then
		return false
	end
	return line:match(M.config.task_start .. M.config.checkbox.pattern) ~= nil
end

--- 通用提取所有ID - 简化版，只提取第一个ID
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

--- 从缓冲区当前行提取所有ID（带安全检查）
function M.extract_ids_from_current_line(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end

	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return {}
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	if not cursor then
		return {}
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local line_num = math.max(1, math.min(cursor[1], line_count))

	local lines = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)
	if not lines or #lines == 0 then
		return {}
	end

	return M.extract_all_ids(lines[1] or "")
end

--- 提取标签 - 完全依赖 id_utils
function M.extract_tag(content)
	if not content then
		return "TODO"
	end

	local tag = id_utils.extract_tag_from_code_mark(content)
	return tag or "TODO"
end

--- 提取代码行中的标签和ID（委托id_utils）
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

function M.get_checkbox_position(line)
	if not line then
		return nil, nil
	end

	return line:find(M.config.checkbox.pattern)
end

function M.get_id_position(line)
	if not line then
		return nil, nil
	end

	return id_utils.find_id_position(line)
end

---------------------------------------------------------------------
-- 清理和格式化
---------------------------------------------------------------------

function M.clean_content(content, tag, options)
	options = options or {}
	if not content then
		return ""
	end

	tag = tag or "TODO"
	local cleaned = content

	if options.full_clean then
		local escaped_tag = tag:gsub("[%-%?%*%+%[%]%(%)%$%^%%%.]", "%%%0")

		cleaned = cleaned:gsub("{#%w+}", "")
		cleaned = cleaned:gsub("^%[" .. escaped_tag .. "%]%s*", "")
		cleaned = cleaned:gsub("^" .. escaped_tag .. ":%s*", "")
		cleaned = cleaned:gsub("^" .. escaped_tag .. "%s+", "")
		cleaned = cleaned:gsub("^%s*[-*+]%s+%[[ xX>]%]%s*", "")
	else
		cleaned = cleaned:gsub("{#%w+}", "")
	end

	return vim.trim(cleaned)
end

function M.format_task_line(options)
	local opts = vim.tbl_extend("force", {
		indent = "",
		checkbox = "[ ]",
		id = nil,
		tag = "TODO",
		content = "",
	}, options or {})

	local clean_content = M.clean_content(opts.content, opts.tag, { full_clean = true })

	local parts = { opts.indent, "- ", opts.checkbox }

	if opts.tag and opts.id then
		table.insert(parts, " " .. opts.tag .. "{#" .. opts.id .. "}")
	elseif opts.id then
		table.insert(parts, " {#" .. opts.id .. "}")
	elseif opts.tag and opts.tag ~= "TODO" then
		table.insert(parts, " " .. opts.tag .. ":")
	end

	if clean_content and clean_content ~= "" then
		table.insert(parts, " " .. clean_content)
	end

	return table.concat(parts, "")
end

---------------------------------------------------------------------
-- 解析任务行
---------------------------------------------------------------------

function M.parse_task_line(line, opts)
	opts = opts or {}
	if not line then
		return nil
	end

	local indent = line:match("^(%s*)") or ""
	local checkbox_match = line:match("^%s*[-*+]%s+(%[[ xX>]%])")
	if not checkbox_match then
		return nil
	end

	local rest = line:match("^%s*[-*+]%s+%[[ xX>]%]%s*(.*)$") or ""

	-- 只从代码标记提取ID
	local id = id_utils.extract_id_from_todo_anchor(rest) or id_utils.extract_id_from_code_mark(rest)

	if id then
		rest = rest:gsub("{#%w+}", "")
		rest = rest:gsub(id_utils.REF_SEPARATOR .. id, "")
	end

	-- 只从代码标记提取标签
	local tag = id_utils.extract_tag_from_code_mark(rest) or "TODO"
	local content = M.clean_content(rest, tag, { full_clean = true })

	local status
	if checkbox_match == "[>]" then
		status = "archived"
	elseif checkbox_match:match("%[[xX]%]") then
		status = "completed"
	else
		status = "normal"
	end

	local result = {
		indent = indent,
		level = #indent / 2,
		checkbox = checkbox_match,
		status = status,
		id = id,
		tag = tag,
		content = content,
		children = {},
		parent = nil,
	}

	if opts.context_fingerprint then
		result.context_fingerprint = opts.context_fingerprint
	end

	return result
end

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
