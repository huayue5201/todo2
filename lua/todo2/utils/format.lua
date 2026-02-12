-- lua/todo2/utils/format.lua
local M = {}

---------------------------------------------------------------------
-- 格式配置中心 - 集中所有硬编码的模式
---------------------------------------------------------------------
M.config = {
	-- 复选框格式（⭐ 新增 archived）
	checkbox = {
		todo = "[ ]",
		done = "[x]",
		archived = "[>]", -- ⭐ 新增
		pattern = "%[[ xX>]%]", -- ⭐ 更新，匹配 [ ]、[x]、[X]、[>]
		pattern_todo = "%[ %]", -- 只匹配 [ ]
		pattern_done = "%[[xX]%]", -- 只匹配 [x] 或 [X]
	},

	-- ID格式
	id = {
		pattern = "{#(%w+)}",
		template = "{#%s}", -- 用于生成
	},

	-- 标签格式（按优先级排列）
	tag_formats = {
		{ pattern = "([A-Z][A-Z0-9]+){#%w+}", name = "id_suffix" }, -- TAG{#id}
		{ pattern = "%[([A-Z][A-Z0-9]*)%]", name = "bracket" }, -- [TAG]
		{ pattern = "([A-Z][A-Z0-9]*):", name = "colon" }, -- TAG:
		{ pattern = "([A-Z][A-Z0-9]*)%s", name = "space" }, -- TAG 内容
	},

	-- 代码注释格式
	code_pattern = "([A-Z][A-Z0-9]+):ref:(%w+)",

	-- 任务行开始模式
	task_start = "^%s*[-*+]%s+",

	-- 清理模式（用于移除标签前缀）
	clean_patterns = {
		{ pattern = "^%[([A-Z][A-Z0-9]+)%]%s*", replacement = "" },
		{ pattern = "^([A-Z][A-Z0-9]+):%s*", replacement = "" },
		{ pattern = "^([A-Z][A-Z0-9]+)%s+", replacement = "" },
		{ pattern = "^%s*[-*+]%s+%[[ xX>]%]%s*[A-Z][A-Z0-9]+{#%w+}%s*", replacement = "%1 " }, -- ⭐ 允许 [>]
		{ pattern = "^%s*[-*+]%s+%[[ xX>]%]%s*%[[A-Z][A-Z0-9]+%]%s*", replacement = "%1 " },
		{ pattern = "^%s*[-*+]%s+%[[ xX>]%]%s*[A-Z][A-Z0-9]+:%s*", replacement = "%1 " },
		{ pattern = "^%s*[-*+]%s+%[[ xX>]%]%s*[A-Z][A-Z0-9]+%s+", replacement = "%1 " },
	},
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
	return line:match(M.config.id.pattern)
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
	local tag, id = code_line:match(M.config.code_pattern)
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

	local id = M.extract_id(line)
	if not id then
		return nil, nil
	end

	local pattern = M.config.id.pattern
	local find_pattern = pattern:gsub("%(%w+%)", "%%w+")
	local start_col, end_col = line:find(find_pattern)

	return start_col, end_col
end

---------------------------------------------------------------------
-- 清理任务行内容，去除元数据（标签、ID、优先级等）
---------------------------------------------------------------------
function M.clean_content(content, tag)
	if not content then
		return ""
	end

	tag = tag or "TODO"

	local function escape_pattern(s)
		return s:gsub("[%-%?%*%+%[%]%(%)%$%^%%%.]", "%%%0")
	end
	local escaped_tag = escape_pattern(tag)

	local cleaned = content

	for _, entry in ipairs(M.config.clean_patterns) do
		local pat = entry.pattern

		pat = pat:gsub("%[A-Z%]%[A-Z0-9%]%+", escaped_tag)
		pat = pat:gsub("%[TAG%]", escaped_tag)

		cleaned = cleaned:gsub(pat, entry.replacement)
	end

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
-- 解析函数（⭐ 增加 [>] 支持）
---------------------------------------------------------------------
--- 解析任务行
function M.parse_task_line(line)
	if not line then
		return nil
	end

	-- 基本匹配
	local indent = line:match("^(%s*)") or ""
	local checkbox_match = line:match("^%s*[-*+]%s+(%[[ xX>]%])") -- ⭐ 允许 [>]
	if not checkbox_match then
		return nil
	end

	-- 提取剩余部分
	local rest = line:match("^%s*[-*+]%s+%[[ xX>]%]%s*(.*)$") or ""

	-- 提取ID
	local id = M.extract_id(rest)
	if id then
		rest = rest:gsub(M.config.id.pattern, "")
	end

	-- 提取标签
	local tag = M.extract_tag(rest)

	-- 清理标签前缀
	local content = M.clean_content(rest, tag)

	-- ⭐ 判断状态
	local completed = checkbox_match ~= "[ ]" -- 非待办即为“完成”类状态
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
		level = #indent / 2, -- 假设缩进为2空格
		checkbox = checkbox_match,
		status = status, -- ⭐ 统一状态字段
		completed = completed, -- 保留兼容字段
		id = id,
		tag = tag,
		content = content,
		children = {},
		parent = nil,
	}
end

return M
