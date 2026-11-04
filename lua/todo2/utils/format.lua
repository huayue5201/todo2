-- lua/todo2/utils/format.lua
-- TODO 文件的行格式：解析与写入的唯一入口。
--
--     <indent>- [<cb>] <content>  @id(x) @created(ts) @due(YYYY-MM-DD) #tag
--
-- 行上的每个非正文字段都由 utils/meta.lua 负责，本模块只处理
-- 缩进 / 项目符号 / checkbox 这些结构性部分。

local M = {}

local types = require("todo2.store.types")
local meta = require("todo2.utils.meta")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------

---@class FormatConfig
---@field checkbox table
---@field task_start string

---@type FormatConfig
M.config = {
	checkbox = {
		-- 任意单字符：未知 checkbox 仍被当作任务行，状态回退由 status.resolve 负责
		pattern = "%[[^%]]%]",
	},
	task_start = "^%s*[-*+]%s+",
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
	local parsed = M.parse_task_line(line)
	return parsed and parsed.id or nil
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
---@param options { indent?: string, checkbox?: string, id?: string, content?: string, tags?: string[], created?: number, start?: string, due?: string, done?: number, archived?: number }
---@return string line
function M.format_task_line(options)
	local opts = vim.tbl_extend("force", {
		indent = "",
		checkbox = "[ ]",
		content = "",
	}, options or {})

	local parts = { opts.indent, "- ", opts.checkbox }

	if opts.content and opts.content ~= "" then
		table.insert(parts, " " .. opts.content)
	end

	table.insert(
		parts,
		meta.format({
			id = opts.id,
			created = opts.created,
			start = opts.start,
			due = opts.due,
			done = opts.done,
			archived = opts.archived,
			tags = opts.tags,
		})
	)

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

	local indent = line:match("^(%s*)") or ""
	local checkbox = line:match("^%s*[-*+]%s+(%[[^%]]%])")
	if not checkbox then
		return nil
	end

	local rest = line:match("^%s*[-*+]%s+%[[^%]]%]%s*(.*)$") or ""
	local fields, content, meta_start = meta.parse(rest)

	return {
		indent = indent,
		level = #indent / 2,
		checkbox = checkbox,
		status = types.checkbox_to_status(checkbox:lower()),
		id = fields.id,
		created = fields.created,
		start = fields.start,
		due = fields.due,
		done = fields.done,
		archived = fields.archived,
		tags = fields.tags,
		-- 元数据块的原文（含前导空白），渲染按它定位块起点：
		-- 手写顺序与规范顺序不同时，长度也会不同，不能拿 meta.format 的长度倒推。
		meta = meta_start and rest:sub(meta_start) or "",
		content = vim.trim(content),
		children = {},
		parent = nil,
		context_fingerprint = opts.context_fingerprint,
	}
end

---任务正文结束处的列（0-based，字节位置），即元数据块之前的位置。
---光标定位一律用它，别用 `#line`：行尾是元数据，落在那儿用户就得先删掉一堆 `@`。
---@param line string
---@return integer col
function M.content_end_col(line)
	local parsed = M.parse_task_line(line or "")
	if not parsed then
		return #(line or "")
	end
	return #parsed.indent + 2 + #parsed.checkbox + 1 + #parsed.content
end

---从任务记录派生「行上必须与 store 保持一致」的字段（唯一来源）。
---任何写回 TODO 行的路径都必须经由这里，否则新加字段就会在改写时丢失。
---@param task table|nil
---@return { created: number|nil, start: string|nil, due: string|nil, done: number|nil, archived: number|nil, tags: string[]|nil }
function M.task_fields(task)
	local core = task and task.core or {}
	local ts = task and task.timestamps or {}
	return {
		created = ts.created,
		start = core.start,
		due = core.due,
		done = ts.completed,
		archived = ts.archived,
		tags = core.tags,
	}
end

---用任务记录渲染整行：布局信息由调用方给，记录字段自动带全。
---@param task table
---@param opts { indent: string, checkbox: string, id: string, content: string }
---@return string
function M.task_line(task, opts)
	local fields = M.task_fields(task)
	return M.format_task_line({
		indent = opts.indent,
		checkbox = opts.checkbox,
		id = opts.id,
		content = opts.content,
		tags = fields.tags,
		created = fields.created,
		start = fields.start,
		due = fields.due,
		done = fields.done,
		archived = fields.archived,
	})
end

return M
