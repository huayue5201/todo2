-- 文件位置：lua/todo2/utils/format.lua
local M = {}

---------------------------------------------------------------------
-- 格式配置中心 - 集中所有硬编码的模式
---------------------------------------------------------------------
M.config = {
	-- 复选框格式
	checkbox = {
		todo = "[ ]",
		done = "[x]",
		pattern = "%[[ xX]%]", -- 匹配 [ ]、[x]、[X]
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
		{ pattern = "^%s*[-*+]%s+%[[ xX]%]%s*[A-Z][A-Z0-9]+{#%w+}%s*", replacement = "%1 " },
		{ pattern = "^%s*[-*+]%s+%[[ xX]%]%s*%[[A-Z][A-Z0-9]+%]%s*", replacement = "%1 " },
		{ pattern = "^%s*[-*+]%s+%[[ xX]%]%s*[A-Z][A-Z0-9]+:%s*", replacement = "%1 " },
		{ pattern = "^%s*[-*+]%s+%[[ xX]%]%s*[A-Z][A-Z0-9]+%s+", replacement = "%1 " },
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

	-- 找到复选框的开始和结束位置
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
	-- 将模式中的捕获组去掉，用于查找位置
	local find_pattern = pattern:gsub("%(%w+%)", "%%w+")
	local start_col, end_col = line:find(find_pattern)

	return start_col, end_col
end

---------------------------------------------------------------------
-- 清理和格式化函数
---------------------------------------------------------------------

--- 清理内容中的标签前缀
function M.clean_content(content, tag)
	if not content then
		return content or ""
	end
	if not tag then
		tag = "([A-Z][A-Z0-9]+)"
	end

	local cleaned = content

	for _, pattern in ipairs(M.config.clean_patterns) do
		local specific_pattern = pattern.pattern
		-- 如果模式中包含[A-Z][A-Z0-9]+，替换为具体标签
		specific_pattern = specific_pattern:gsub("%[A-Z%]%[A-Z0-9%]%+", tag)
		specific_pattern = specific_pattern:gsub("([A-Z][A-Z0-9]+)", tag)

		cleaned = cleaned:gsub(specific_pattern, pattern.replacement)
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
-- 解析函数
---------------------------------------------------------------------
--- 解析任务行
function M.parse_task_line(line)
	if not line then
		return nil
	end

	-- 基本匹配
	local indent = line:match("^(%s*)") or ""
	local checkbox_match = line:match("^%s*[-*+]%s+(%[[ xX]%])")
	if not checkbox_match then
		return nil
	end

	-- 提取剩余部分
	local rest = line:match("^%s*[-*+]%s+%[[ xX]%]%s*(.*)$") or ""

	-- 提取ID
	local id = M.extract_id(rest)
	if id then
		rest = rest:gsub(M.config.id.pattern, "")
	end

	-- 提取标签
	local tag = M.extract_tag(rest)

	-- 清理标签前缀
	local content = M.clean_content(rest, tag)

	-- ⭐ 修改：使用 completed 替代 is_done
	local completed = checkbox_match == "[x]" or checkbox_match == "[X]"

	return {
		indent = indent,
		level = #indent / 2, -- 假设缩进为2空格
		checkbox = checkbox_match,
		status = checkbox_match,
		completed = completed, -- ⭐ 修改：使用 completed
		id = id,
		tag = tag,
		content = content,
		children = {},
		parent = nil,
	}
end
return M
