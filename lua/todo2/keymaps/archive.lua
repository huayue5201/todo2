-- lua/todo2/keymaps/archive.lua
-- 只负责UI交互，业务逻辑委托给 core.archive

local M = {}

local core_archive = require("todo2.core.archive")
local ui = require("todo2.ui")

function M.archive_task_group()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")

	-- 获取当前任务（复用 parser 缓存）
	local parser = require("todo2.core.parser")
	local path = vim.api.nvim_buf_get_name(bufnr)
	local tasks, roots = parser.parse_file(path, false) -- 使用缓存

	-- 找到当前行的任务
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

	-- 找到根任务
	local root = current_task
	while root.parent do
		root = root.parent
	end

	-- 预览归档影响（复用 core_archive 的逻辑）
	local preview = core_archive.preview_archive(bufnr)
	vim.notify(M._format_preview(preview), vim.log.levels.INFO)

	-- 确认归档
	local confirm =
		vim.fn.confirm(string.format("确定归档任务组 '%s' 吗？", root.content:sub(1, 30)), "&Yes\n&No", 2)

	if confirm == 1 then
		local ok, msg, result = core_archive.archive_task_group(root, bufnr)
		if ok then
			vim.notify("✅ " .. msg, vim.log.levels.INFO)
			ui.refresh(bufnr, true)
		else
			vim.notify("❌ " .. msg, vim.log.levels.ERROR)
		end
	end
end

function M.restore_task()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]

	local id = line:match("{#(%w+)}")
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

-- UI 预览格式化
function M._format_preview(preview)
	local lines = {}

	table.insert(lines, "📦 归档预览")
	table.insert(
		lines,
		string.format("发现 %d 个可归档任务组，共 %d 个任务", preview.total_groups, preview.total_tasks)
	)
	table.insert(lines, "")

	for _, group in ipairs(preview.groups) do
		if group.can_archive then
			table.insert(lines, string.format("✅ %s", group.root.content:sub(1, 50)))
			table.insert(lines, string.format("   └─ %d个任务", group.task_count))
			table.insert(lines, "")
		end
	end

	return table.concat(lines, "\n")
end

return M
