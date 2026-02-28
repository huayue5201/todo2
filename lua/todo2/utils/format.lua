-- lua/todo2/utils/format.lua
local M = {}

local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 格式配置中心 - 集中所有硬编码的模式
---------------------------------------------------------------------
M.config = {
	-- 复选框格式
	checkbox = {
		todo = "[ ]",
		done = "[x]",
		archived = "[>]",
		pattern = "%[[ xX>]%]",
		pattern_todo = "%[ %]",
		pattern_done = "%[[xX]%]",
	},

	-- ID格式 - 复用 id_utils 的配置
	id = {
		pattern = id_utils.TODO_ANCHOR_PATTERN,
		template = "{#%s}",
	},

	-- 标签格式（按优先级排列）
	tag_formats = {
		{ pattern = "([A-Z][A-Z0-9]+){#%w+}", name = "id_suffix" }, -- TAG{#id}
		{ pattern = "%[([A-Z][A-Z0-9]*)%]", name = "bracket" }, -- [TAG]
		{ pattern = "([A-Z][A-Z0-9]*):", name = "colon" }, -- TAG:
		{ pattern = "([A-Z][A-Z0-9]*)%s", name = "space" }, -- TAG 内容
	},

	-- 代码注释格式 - 复用 id_utils 的正则
	code_pattern = id_utils.CODE_MARK_PATTERN,

	-- 任务行开始模式
	task_start = "^%s*[-*+]%s+",
}

---------------------------------------------------------------------
-- 基础判断函数
---------------------------------------------------------------------

--- 判断是否为任务行
function M.is_task_line(line)
	if not line then
		return false
	end
	return line:match(M.config.task_start .. M.config.checkbox.pattern) ~= nil
end

---------------------------------------------------------------------
-- 提取函数
---------------------------------------------------------------------

--- 提取任务ID
function M.extract_id(line)
	if not line then
		return nil
	end
	return id_utils.extract_id(line)
end

--- 提取标签（从任务内容中）
function M.extract_tag(content)
	if not content then
		return "TODO"
	end

	for _, fmt in ipairs(M.config.tag_formats) do
		local tag = content:match(fmt.pattern)
		if tag then
			return tag
		end
	end

	return "TODO"
end

--- 提取代码行中的标签和ID
function M.extract_from_code_line(code_line)
	if not code_line then
		return "TODO", nil
	end
	local tag = id_utils.extract_tag_from_code_mark(code_line)
	local id = id_utils.extract_id_from_code_mark(code_line)
	return tag or "TODO", id
end

---------------------------------------------------------------------
-- 位置计算函数
---------------------------------------------------------------------

--- 获取复选框位置
function M.get_checkbox_position(line)
	if not line then
		return nil, nil
	end

	local start_col, end_col = line:find(M.config.checkbox.pattern)
	if start_col then
		return start_col, end_col
	end

	return nil, nil
end

--- 获取ID位置
function M.get_id_position(line)
	if not line then
		return nil, nil
	end

	local start_pos, end_pos = id_utils.find_id_position(line)
	return start_pos, end_pos
end

---------------------------------------------------------------------
-- 清理任务行内容，去除元数据（标签、ID等）
---------------------------------------------------------------------
function M.clean_content(content, tag)
	if not content then
		return ""
	end

	tag = tag or "TODO"
	local escaped_tag = tag:gsub("[%-%?%*%+%[%]%(%)%$%^%%%.]", "%%%0")

	local cleaned = content

	-- 移除 ID 标记
	cleaned = cleaned:gsub(id_utils.TODO_ANCHOR_PATTERN_NO_CAPTURE, "")

	-- 移除标签前缀（多种格式）
	cleaned = cleaned:gsub("^%[" .. escaped_tag .. "%]%s*", "")
	cleaned = cleaned:gsub("^" .. escaped_tag .. ":%s*", "")
	cleaned = cleaned:gsub("^" .. escaped_tag .. "%s+", "")

	-- 移除复选框和列表标记（如果存在）
	cleaned = cleaned:gsub("^%s*[-*+]%s+%[[ xX>]%]%s*", "")

	return vim.trim(cleaned)
end

--- 格式化任务行
function M.format_task_line(options)
	local opts = vim.tbl_extend("force", {
		indent = "",
		checkbox = "[ ]",
		id = nil,
		tag = "TODO",
		content = "",
	}, options or {})

	-- 清理内容中的标签前缀
	local clean_content = M.clean_content(opts.content, opts.tag)

	-- 构建任务行
	local parts = { opts.indent, "- ", opts.checkbox }

	-- 添加标签和ID
	if opts.tag and opts.id then
		table.insert(parts, " " .. opts.tag .. id_utils.format_todo_anchor(opts.id))
	elseif opts.id then
		table.insert(parts, " " .. id_utils.format_todo_anchor(opts.id))
	elseif opts.tag and opts.tag ~= "TODO" then
		table.insert(parts, " " .. opts.tag .. ":")
	end

	-- 添加清理后的内容
	if clean_content and clean_content ~= "" then
		table.insert(parts, " " .. clean_content)
	end

	return table.concat(parts, "")
end

---------------------------------------------------------------------
-- 解析函数
---------------------------------------------------------------------
-- ⭐ 新增：生成上下文指纹所需的规范化内容
function M.normalize_for_context(content)
	if not content then
		return ""
	end
	-- 移除行内注释
	content = content:gsub("%-%-.*$", "")
	content = content:gsub("//.*$", "")
	content = content:gsub("#.*$", "")
	-- 规范化空白
	content = content:gsub("^%s+", "")
	content = content:gsub("%s+$", "")
	content = content:gsub("%s+", " ")
	return content
end

-- ⭐ 新增：从任务行提取完整上下文信息
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

-- ⭐ 修改 parse_task_line 函数，添加上下文指纹支持
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

	local id = M.extract_id(rest)
	if id then
		rest = rest:gsub(id_utils.TODO_ANCHOR_PATTERN_NO_CAPTURE, "")
	end

	local tag = M.extract_tag(rest)
	local content = M.clean_content(rest, tag)

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

	-- ⭐ 如果提供了上下文指纹，保存
	if opts.context_fingerprint then
		result.context_fingerprint = opts.context_fingerprint
	end

	return result
end

return M
