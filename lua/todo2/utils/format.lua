-- lua/todo2/utils/format.lua
-- 精简版：只处理 TODO 文件格式

local M = {}

local id_utils = require("todo2.utils.id")
local types = require("todo2.store.types")
local tags_utils = require("todo2.utils.tags")

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

--- 获取任务标记（<status>:<id>）的位置
---@param line string
---@return number|nil start, number|nil end_
function M.get_mark_position(line)
	if not line then
		return nil, nil
	end
	local _, mark = id_utils.extract_mark(line)
	if not mark then
		return nil, nil
	end
	return line:find(mark, 1, true)
end

---------------------------------------------------------------------
-- 格式化任务行（写入）
---------------------------------------------------------------------

--- 格式化任务行（写入 TODO 文件）
---@param options { indent?: string, checkbox?: string, id?: string, status?: string, content?: string, tags?: string[] }
---@return string line
function M.format_task_line(options)
	local opts = vim.tbl_extend("force", {
		indent = "",
		checkbox = "[ ]",
		id = nil,
		status = nil,
		content = "",
	}, options or {})

	local parts = { opts.indent, "- ", opts.checkbox }

	if opts.id then
		-- 标记前缀取自任务状态；未显式给出时从 checkbox 推导（终态），否则用默认循环状态
		local status = opts.status or types.checkbox_to_status((opts.checkbox or ""):lower())
		table.insert(parts, " " .. id_utils.format_mark(opts.id, status))

		-- 标签段：紧跟标记之后、内容之前
		local tag_segment = tags_utils.format(opts.tags)
		if tag_segment ~= "" then
			table.insert(parts, tag_segment)
		end
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

	-- 提取 <status>:ID 标记
	local id, mark = id_utils.extract_mark(rest)

	-- 移除标记；其后的连续 #tag 序列属于标签段，其余为内容
	local tags = {}
	if mark then
		rest = rest:gsub(vim.pesc(mark), "")
		tags, rest = tags_utils.extract(rest)
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
		mark = mark,
		tags = tags,
		content = content,
		children = {},
		parent = nil,
		context_fingerprint = opts.context_fingerprint,
	}
end

return M
