-- lua/todo2/keymaps/archive.lua
-- 只负责 UI 交互，不做业务逻辑，不做渲染，不做刷新

local M = {}

local core_archive = require("todo2.core.archive")
local id_utils = require("todo2.utils.id")
local config = require("todo2.config")
local link = require("todo2.store.link")

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

	-- ⭐ 调用核心归档逻辑（内部会触发事件 → scheduler 自动刷新）
	local ok, msg = core_archive.archive_task_group(root, bufnr)

	if ok then
		vim.notify("✅ " .. msg, vim.log.levels.INFO)
		-- ❌ 不要刷新（事件系统会自动刷新）
	else
		vim.notify("❌ " .. msg, vim.log.levels.ERROR)
	end
end

function M.restore_task()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]

	if not line or line == "" then
		vim.notify("当前行不是归档任务", vim.log.levels.WARN)
		return
	end

	-- ⭐ 直接从行里拿 ID
	local id = id_utils.extract_id_from_todo_anchor(line)
	if not id then
		vim.notify("当前行不是归档任务", vim.log.levels.WARN)
		return
	end

	-- ⭐ 用存储层判断是不是归档任务，而不是靠“区域”
	local todo_link = link.get_todo(id )
	if not todo_link or todo_link.status ~= "archived" then
		vim.notify("当前任务不是归档任务", vim.log.levels.WARN)
		return
	end

	-- ⭐ 调用核心撤销归档逻辑（内部会触发事件 → scheduler 自动刷新）
	local ok, msg = core_archive.unarchive_task_group(id, bufnr)

	if ok then
		vim.notify("✅ " .. msg, vim.log.levels.INFO)
	else
		vim.notify("❌ " .. msg, vim.log.levels.ERROR)
	end
end

return M
