-- lua/todo2/utils/format.lua
-- 完整修复版：正确处理空行和规范化

local M = {}

local id_utils = require("todo2.utils.id")

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

	-- ⭐ 新增：空行标记常量
	EMPTY_LINE_MARKER = "__EMPTY_LINE__",
	NORMAL_LINE_MARKER = "__NORMAL_LINE__",
}

---------------------------------------------------------------------
-- 代码行规范化（用于上下文指纹）
---------------------------------------------------------------------

--- 规范化代码行，移除注释但保留结构标记
--- @param line string 原始代码行
--- @param options table|nil 配置选项
--- @return string 规范化后的内容
function M.normalize_code_line(line, options)
	options = options or {}
	if not line then
		return ""
	end

	-- ⭐ 修复：处理空行 - 保留一个标记表示这是空行
	if line:match("^%s*$") then
		return options.keep_indent and line or M.config.EMPTY_LINE_MARKER
	end

	-- 创建副本用于规范化
	local normalized = line

	-- 检测注释类型并保留标记
	if normalized:match("^%s*%-%-") then
		-- Lua/Rust/SQL 注释行，保留 "--" 作为结构标记
		normalized = normalized:gsub("%-%-.*$", "--")
	elseif normalized:match("^%s*//") then
		-- C/C++/JS/Rust 注释，保留 "//"
		normalized = normalized:gsub("//.*$", "//")
	elseif normalized:match("^%s*#") then
		-- Python/Ruby/Shell 注释，保留 "#"
		normalized = normalized:gsub("#.*$", "#")
	else
		-- 非注释行，正常移除行内注释
		normalized = normalized:gsub("%-%-.*$", "")
		normalized = normalized:gsub("//.*$", "")
		normalized = normalized:gsub("#.*$", "")
	end

	-- 规范化空白
	normalized = normalized:gsub("^%s+", "")
	normalized = normalized:gsub("%s+$", "")
	normalized = normalized:gsub("%s+", " ")

	-- 如果需要保留原始缩进信息（用于结构提取）
	if options.keep_indent then
		local indent = line:match("^(%s*)") or ""
		normalized = indent .. normalized
	end

	-- 如果规范化后为空，标记为普通行
	if normalized == "" then
		normalized = M.config.NORMAL_LINE_MARKER
	end

	return normalized
end

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
-- ID 提取工具函数（新增）
---------------------------------------------------------------------
--- 从缓冲区当前行提取ID（带安全检查）
--- @param bufnr number|nil 缓冲区编号（nil表示当前缓冲区）
--- @return table ID列表
function M.extract_ids_from_current_line(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- 1. 检查缓冲区有效性
	if bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("缓冲区无效或已关闭", vim.log.levels.DEBUG)
		return {}
	end

	-- 2. 检查缓冲区是否加载
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return {}
	end

	-- 3. 安全获取光标位置
	local cursor
	local ok, result = pcall(vim.api.nvim_win_get_cursor, 0)
	if ok and result then
		cursor = result
	else
		-- 如果无法获取光标，尝试使用缓冲区第一行
		cursor = { 1, 0 }
	end

	-- 4. 确保行号有效
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local line_num = math.max(1, math.min(cursor[1], line_count))

	-- 5. 安全读取行内容
	local lines
	ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, line_num - 1, line_num, false)
	if not ok or not lines or #lines == 0 then
		return {}
	end

	-- 6. 提取ID
	return M.extract_all_ids(lines[1] or "")
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
-- ⭐ 修复版：清理任务行内容，去除元数据（标签、ID等）
---------------------------------------------------------------------
function M.clean_content(content, tag, options)
	options = options or {}
	if not content then
		return ""
	end

	tag = tag or "TODO"
	local cleaned = content

	-- ⭐ 修复：只在完全清理模式下移除标签前缀
	if options.full_clean then
		local escaped_tag = tag:gsub("[%-%?%*%+%[%]%(%)%$%^%%%.]", "%%%0")

		-- 移除 ID 标记
		cleaned = cleaned:gsub(id_utils.TODO_ANCHOR_PATTERN_NO_CAPTURE, "")

		-- 移除标签前缀
		cleaned = cleaned:gsub("^%[" .. escaped_tag .. "%]%s*", "")
		cleaned = cleaned:gsub("^" .. escaped_tag .. ":%s*", "")
		cleaned = cleaned:gsub("^" .. escaped_tag .. "%s+", "")

		-- 移除复选框和列表标记
		cleaned = cleaned:gsub("^%s*[-*+]%s+%[[ xX>]%]%s*", "")
	else
		-- ⭐ 默认模式：只移除 ID 标记，保留标签前缀（用于上下文）
		cleaned = cleaned:gsub(id_utils.TODO_ANCHOR_PATTERN_NO_CAPTURE, "")
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
	local clean_content = M.clean_content(opts.content, opts.tag, { full_clean = true })

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

--- 从任务行提取完整上下文信息
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

--- 解析任务行
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

return M
