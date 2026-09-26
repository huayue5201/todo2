-- lua/todo2/utils/format.lua
-- 精简版：只处理 TODO 文件格式

local M = {}

local id_utils = require("todo2.utils.id")
local types = require("todo2.store.types")

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
		pattern = "%[[ xX>]%]",
	},
	task_start = "^%s*[-*+]%s+",
	EMPTY_LINE_MARKER = "__EMPTY_LINE__",
	NORMAL_LINE_MARKER = "__NORMAL_LINE__",
}

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

--- 从任务行提取 ID
---@param line string
---@return string|nil
function M.extract_id_from_line(line)
	if not line then
		return nil
	end
	return id_utils.extract_id_from_line(line)
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

---------------------------------------------------------------------
-- 格式化任务行（写入）
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
-- 解析任务行（读取）
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
	local tag = id_utils.extract_tag_from_line(rest)
	local id = id_utils.extract_id_from_line(rest)

	-- 移除 TAG:ref:ID
	if tag and id then
		local mark = id_utils.format_mark(tag, id)
		rest = rest:gsub(vim.pesc(mark), "")
	end

	-- content 永远纯文本
	local content = vim.trim(rest)

	-- 状态（统一由 types 映射 checkbox → status）
	local status = types.checkbox_to_status(checkbox_match:lower())

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

return M
