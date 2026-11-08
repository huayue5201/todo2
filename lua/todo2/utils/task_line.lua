-- lua/todo2/utils/task_line.lua
-- 把 store 里的任务字段写回 TODO 文件的整行。
--
-- 用途：改内容 / 改标签 / 状态写回等需要「文件 + store」保持一致的地方。
-- 所有写入统一走 core/line_edit：先在内存里算好新行，再一次性写 buffer 并同步。

local M = {}

local core = require("todo2.store.task.core")
local types = require("todo2.store.types")
local file = require("todo2.utils.file")
local format = require("todo2.utils.format")
local meta = require("todo2.utils.meta")
local line_edit = require("todo2.core.line_edit")

---正文末尾写了形如 `@id(x)` / `#tag` 的 token：写入后会被当成元数据（或标签）解析，
---导致下次读回时正文少了一截。这里提醒一次，用 `\@` 转义可以保留字面量。
---@param id string
---@param content string|nil
local function warn_stray_meta(id, content)
	if not meta.has_trailing_meta(content) then
		return
	end
	vim.notify(
		string.format(
			"todo2: the content of %s ends with metadata-like text that will be parsed away on write; to keep it literal, escape it with a backslash (`\\@due(...)`)",
			id
		),
		vim.log.levels.WARN
	)
end

---重建任务行：indent / checkbox / id / content 来自文件，其余字段来自 store。
---@param task table
---@param parsed table
---@param opts? { content?: string, status?: string }
---@return string
local function build_line(task, parsed, opts)
	opts = opts or {}
	local content = opts.content or parsed.content
	if opts.content then
		warn_stray_meta(task.id, content)
	end
	return format.task_line(task, {
		indent = parsed.indent,
		checkbox = opts.status and types.status_to_checkbox(opts.status) or parsed.checkbox,
		id = parsed.id,
		content = content,
	})
end

---解析指定行，并要求 id 对得上（行被手改/挪动时放弃写入）
---@param lines string[]
---@param lnum integer 1-based
---@param id string
---@return table? parsed
local function parse_line(lines, lnum, id)
	local line = lines[lnum]
	if not line then
		return nil
	end
	local parsed = format.parse_task_line(line)
	if not parsed or parsed.id ~= id then
		return nil
	end
	return parsed
end

---用 store 中的字段重写任务行；opts.content 可覆盖正文（改内容）。
---@param id string
---@param opts? { content?: string, status?: string }
---@return boolean ok, string|nil err
function M.rewrite(id, opts)
	local task = core.get_task(id)
	if not task then
		return false, "task not found: " .. tostring(id)
	end

	local loc = core.get_todo_location(id)
	if not loc or not loc.path or not loc.line then
		return false, "task has no TODO location: " .. tostring(id)
	end

	local lines = file.read_lines_smart(loc.path)
	if not lines then
		return false, "cannot read TODO file: " .. loc.path
	end

	local parsed = parse_line(lines, loc.line, id)
	if not parsed then
		return false, "cannot parse TODO line: " .. tostring(loc.line)
	end

	local edit = { path = loc.path, lnum = loc.line, count = 1, lines = { build_line(task, parsed, opts) } }
	local ok, err = pcall(line_edit.apply, { edit })
	if not ok then
		return false, "write failed: " .. tostring(err)
	end
	return true
end

---把 store 里的状态批量写回 TODO 文件（checkbox），每个文件只写一次再落盘。
---
---文件是状态真相源（sync 以 checkbox 为准），状态由 store 侧写入后必须立刻落到行上，
---否则下一次 sync 会按旧 checkbox 把状态改回去（归档任意任务即触发）。
---@param ids string[]
---@return boolean ok
function M.rewrite_statuses(ids)
	if not ids or #ids == 0 then
		return true
	end

	local by_path = {}
	for _, id in ipairs(ids) do
		local loc = core.get_todo_location(id)
		if loc and loc.path and loc.line then
			by_path[loc.path] = by_path[loc.path] or {}
			table.insert(by_path[loc.path], id)
		end
	end

	local edits = {}
	for path, path_ids in pairs(by_path) do
		local lines = file.read_lines_smart(path)
		if lines then
			for _, id in ipairs(path_ids) do
				local task = core.get_task(id)
				local loc = core.get_todo_location(id)
				local parsed = loc and parse_line(lines, loc.line, id)
				if task and parsed then
					table.insert(edits, {
						path = path,
						lnum = loc.line,
						count = 1,
						lines = { build_line(task, parsed, { status = task.core.status }) },
					})
				end
			end
		end
	end

	if #edits == 0 then
		return true
	end
	return (pcall(line_edit.apply, edits))
end

return M
