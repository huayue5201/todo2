-- lua/todo2/utils/task_line.lua
-- 重写任务在 TODO 文件里的整行，使其与 store 中的状态 / 标签一致。
--
-- 用途：MCP 改标签、Phase 3 状态迁移等需要「文件 + store」保持一致的地方。
-- 优先改已加载的 buffer（并落盘），否则直接写磁盘（不强制加载 buffer）。

local M = {}

local core = require("todo2.store.task.core")
local types = require("todo2.store.types")
local file = require("todo2.utils.file")
local format = require("todo2.utils.format")

---正文里写了形如 `@2026-11-02` 的日期：语法只认 mark 之后的前缀段，
---这种写法不会被当成到期日（也不会生效），这里提醒一次，避免「看着设了、其实没设」。
---@param id string
---@param content string|nil
local function warn_stray_due(id, content)
	local stray = (content or ""):match("@%d%d%d%d%-%d%d%-%d%d")
	if not stray then
		return
	end
	vim.notify(
		string.format(
			"todo2: %s 的正文里含有 %s，它不会被识别为到期日（应写成 `todo:<id> %s <内容>`）",
			id,
			stray,
			stray
		),
		vim.log.levels.WARN
	)
end

--- 同步落盘。
---@param bufnr number
local function save_buf(bufnr)
	pcall(function()
		vim.api.nvim_buf_call(bufnr, function()
			vim.cmd("silent! update")
		end)
	end)
end

--- 用 store 中的 status / tags 重写任务行。
--- opts.content 可覆盖正文（用于改任务内容）；缺省沿用行上已有内容。
--- opts.status 给出时用它的 checkbox / 标记前缀覆盖行上原有值（状态写回用）。
---@param id string
---@param opts? { content?: string, status?: string }
---@return boolean ok, string|nil err
function M.rewrite(id, opts)
	opts = opts or {}
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

	local line = lines[loc.line]
	if not line then
		return false, "TODO line out of range: " .. tostring(loc.line)
	end

	local parsed = format.parse_task_line(line)
	if not parsed or not parsed.id then
		return false, "cannot parse TODO line: " .. tostring(loc.line)
	end

	local content = opts.content or parsed.content
	warn_stray_due(id, content)

	local new_line = format.task_line(task, {
		indent = parsed.indent,
		checkbox = opts.status and types.status_to_checkbox(opts.status) or parsed.checkbox,
		id = parsed.id,
		content = content,
		status = opts.status,
	})

	local bufnr = vim.fn.bufnr(loc.path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, loc.line - 1, loc.line, false, { new_line })
		if not ok then
			return false, "buffer write failed: " .. tostring(err)
		end
		save_buf(bufnr)
		return true
	end

	lines[loc.line] = new_line
	local ok, err = pcall(vim.fn.writefile, lines, loc.path)
	if not ok then
		return false, "write failed: " .. tostring(err)
	end
	return true
end

--- 把 store 里的状态批量写回 TODO 文件（checkbox + 标记前缀），每个文件只写一次再落盘。
---
--- 文件是终态真相源（sync 认 `[ ]` 表示非终态），状态由 store 侧写入后必须立刻落到行上，
--- 否则下一次 sync 会把刚完成的任务按 `[ ]` 打回活跃态（归档任意任务即触发）。
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

	for path, path_ids in pairs(by_path) do
		local bufnr = vim.fn.bufadd(path)
		require("todo2.utils.buffer").ensure_loaded(bufnr)
		if vim.api.nvim_buf_is_valid(bufnr) then
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local dirty = false

			for _, id in ipairs(path_ids) do
				local task = core.get_task(id)
				local loc = core.get_todo_location(id)
				local lnum = loc and loc.line
				local line = lnum and lines[lnum]
				if task and line then
					local parsed = format.parse_task_line(line)
					if parsed and parsed.id == id then
						local new_line = format.task_line(task, {
							indent = parsed.indent,
							checkbox = types.status_to_checkbox(task.core.status),
							id = parsed.id,
							content = parsed.content,
							status = task.core.status,
						})
						if new_line ~= line then
							lines[lnum] = new_line
							dirty = true
						end
					end
				end
			end

			if dirty then
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
				save_buf(bufnr)
			end
		end
	end

	return true
end

return M
