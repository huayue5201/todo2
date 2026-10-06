-- lua/todo2/utils/task_line.lua
-- 重写任务在 TODO 文件里的整行，使其与 store 中的状态 / 标签一致。
--
-- 用途：MCP 改标签、Phase 3 状态迁移等需要「文件 + store」保持一致的地方。
-- 优先改已加载的 buffer（并落盘），否则直接写磁盘（不强制加载 buffer）。

local M = {}

local core = require("todo2.store.task.core")
local file = require("todo2.utils.file")
local format = require("todo2.utils.format")

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
---@param id string
---@return boolean ok, string|nil err
function M.rewrite(id)
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

	local new_line = format.format_task_line({
		indent = parsed.indent,
		checkbox = parsed.checkbox,
		id = parsed.id,
		status = task.core.status,
		tags = task.core.tags,
		content = parsed.content,
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

return M
