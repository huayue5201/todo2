-- lua/todo2/keymaps/archive.lua
-- 只负责UI交互，业务逻辑委托给 core.archive

local M = {}

local core_archive = require("todo2.core.archive")
local ui = require("todo2.ui")
local id_utils = require("todo2.utils.id")
local config = require("todo2.config")

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

	local root = current_task
	while root.parent do
		root = root.parent
	end

	local ok, msg, result = core_archive.archive_task_group(root, bufnr)
	if ok then
		vim.notify("✅ " .. msg, vim.log.levels.INFO)
		ui.refresh(bufnr, true)
	else
		vim.notify("❌ " .. msg, vim.log.levels.ERROR)
	end
end

function M.restore_task()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local in_archive = false
	for i = 1, lnum do
		-- ⭐ 使用配置函数检测归档区域
		if lines[i] and config.is_archive_section_line(lines[i]) then
			in_archive = true
			break
		end
	end

	if not in_archive then
		vim.notify("当前行不在归档区域", vim.log.levels.WARN)
		return
	end

	local id = id_utils.extract_id_from_todo_anchor(line)
	if not id then
		vim.notify("当前行不是归档任务", vim.log.levels.WARN)
		return
	end

	local ok, msg = core_archive.restore_task(id, bufnr)
	if ok then
		vim.notify("✅ " .. msg, vim.log.levels.INFO)
		ui.refresh(bufnr, true)
	else
		vim.notify("❌ " .. msg, vim.log.levels.ERROR)
	end
end

return M
