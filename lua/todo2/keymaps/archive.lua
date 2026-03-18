-- lua/todo2/keymaps/archive.lua
-- UI层：只负责用户交互，调用 core 层
---@module "todo2.keymaps.archive"

local M = {}

local core_archive = require("todo2.core.archive")
local id_utils = require("todo2.utils.id")
local core = require("todo2.store.link.core")

---归档当前任务组
function M.archive_task_group()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")

	local parser = require("todo2.core.parser")
	local path = vim.api.nvim_buf_get_name(bufnr)
	local tasks = parser.parse_file(path, false)

	local current_task
	for _, task in ipairs(tasks) do
		if task.line_num == lnum then
			current_task = task
			break
		end
	end

	if not current_task then
		vim.notify("当前行不是任务", vim.log.levels.WARN)
		return
	end

	-- 找到任务组根节点
	local root = current_task
	while root.parent do
		root = root.parent
	end

	local ok, msg = core_archive.archive_task_group(root, bufnr)

	if ok then
		vim.notify("✅ " .. msg, vim.log.levels.INFO)
	else
		vim.notify("❌ " .. msg, vim.log.levels.ERROR)
	end
end

---恢复归档任务
function M.restore_task()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]

	if not line or line == "" then
		vim.notify("当前行不是归档任务", vim.log.levels.WARN)
		return
	end

	local id = id_utils.extract_id_from_todo_anchor(line)
	if not id then
		vim.notify("当前行不是归档任务", vim.log.levels.WARN)
		return
	end

	local task = core.get_task(id)
	if not task or task.core.status ~= "archived" then
		vim.notify("当前任务不是归档任务", vim.log.levels.WARN)
		return
	end

	local ok, msg = core_archive.unarchive_task_group(id, bufnr)

	if ok then
		vim.notify("✅ " .. msg, vim.log.levels.INFO)
	else
		vim.notify("❌ " .. msg, vim.log.levels.ERROR)
	end
end

return M
