-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- @brief 归档系统核心模块（极简版）

local M = {}

---------------------------------------------------------------------
-- 模块导入
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 归档配置
---------------------------------------------------------------------
local ARCHIVE_CONFIG = {
	ARCHIVE_SECTION_PREFIX = "## Archived",
	DATE_FORMAT = "%Y-%m",
}

---------------------------------------------------------------------
-- 归档算法核心
---------------------------------------------------------------------

--- 检查任务是否可归档（递归检查子树）
local function check_task_archivable(task, all_tasks)
	if not task or not task.is_done then
		return false, {}
	end

	-- 叶子节点：完成即可归档
	if #task.children == 0 then
		return true, { task }
	end

	-- 非叶子节点：检查所有子节点
	local all_children_archivable = true
	local archive_subtree = { task }

	for _, child in ipairs(task.children) do
		local child_archivable, child_subtree = check_task_archivable(child, all_tasks)
		if not child_archivable then
			all_children_archivable = false
			break
		else
			for _, child_task in ipairs(child_subtree) do
				table.insert(archive_subtree, child_task)
			end
		end
	end

	if all_children_archivable then
		return true, archive_subtree
	else
		return false, {}
	end
end

--- 获取文件中所有可归档的任务
function M.get_archivable_tasks(bufnr)
	local parser = module.get("core.parser")
	local path = vim.api.nvim_buf_get_name(bufnr)

	if path == "" or not path:match("%.todo%.md$") then
		return {}
	end

	local tasks, roots = parser.parse_file(path)
	local archivable_tasks = {}
	local visited = {}

	local function dfs(task)
		if visited[task] then
			return
		end
		visited[task] = true

		local archivable, subtree = check_task_archivable(task, tasks)
		if archivable then
			for _, t in ipairs(subtree) do
				archivable_tasks[t] = true
			end
			return
		end

		for _, child in ipairs(task.children) do
			dfs(child)
		end
	end

	for _, root in ipairs(roots) do
		dfs(root)
	end

	local result = {}
	for task, _ in pairs(archivable_tasks) do
		table.insert(result, task)
	end

	table.sort(result, function(a, b)
		return a.line_num > b.line_num
	end)

	return result
end

---------------------------------------------------------------------
-- 归档区域管理
---------------------------------------------------------------------

--- 查找或创建归档区域
local function find_or_create_archive_section(lines, month)
	local section_header = ARCHIVE_CONFIG.ARCHIVE_SECTION_PREFIX .. " (" .. month .. ")"

	for i, line in ipairs(lines) do
		if line == section_header then
			for j = i + 1, #lines do
				if lines[j]:match("^## ") or j == #lines then
					return j, false
				end
			end
			return #lines + 1, false
		end
	end

	local insert_pos = #lines + 1

	if insert_pos > 1 and lines[insert_pos - 1] ~= "" then
		table.insert(lines, insert_pos, "")
		insert_pos = insert_pos + 1
	end

	table.insert(lines, insert_pos, section_header)
	return insert_pos + 1, true
end

---------------------------------------------------------------------
-- 核心归档功能
---------------------------------------------------------------------

--- 安全删除代码标记
local function safe_delete_code_marker(store, task_id)
	local code_link = store.get_code_link(task_id)
	if not code_link or not code_link.path or not code_link.line then
		return false
	end

	local code_bufnr = vim.fn.bufadd(code_link.path)
	vim.fn.bufload(code_bufnr)

	local code_line = vim.api.nvim_buf_get_lines(code_bufnr, code_link.line - 1, code_link.line, false)[1] or ""

	if not code_line:match(task_id) then
		return false
	end

	local success = pcall(function()
		vim.api.nvim_buf_set_lines(code_bufnr, code_link.line - 1, code_link.line, false, {})

		vim.api.nvim_buf_call(code_bufnr, function()
			vim.cmd("noautocmd silent write")
		end)
	end)

	if success then
		store.delete_code_link(task_id)
		return true
	end

	return false
end

--- 安全归档存储记录
local function safe_archive_store_record(store, task_id)
	local todo_link = store.get_todo_link(task_id)
	if not todo_link then
		return false
	end

	local now = os.time()

	local original_status = todo_link.status or "normal"
	local original_completed_at = todo_link.completed_at
	local original_previous_status = todo_link.previous_status

	todo_link.archived_at = now
	todo_link.archived_reason = "project_completed"
	todo_link.updated_at = now

	todo_link.status = original_status
	todo_link.completed_at = original_completed_at
	todo_link.previous_status = original_previous_status

	local key = "todo.links.todo." .. task_id
	if store.set_key then
		store.set_key(key, todo_link)
		return true
	end

	return false
end

--- 执行归档操作
function M.archive_tasks(bufnr, tasks)
	if #tasks == 0 then
		return false, "没有可归档的任务", 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" or not path:match("%.todo%.md$") then
		return false, "当前不是TODO文件", 0
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not lines then
		return false, "无法读取文件", 0
	end

	-- 按月份分组任务
	local month_groups = {}
	for _, task in ipairs(tasks) do
		local month = os.date(ARCHIVE_CONFIG.DATE_FORMAT)
		month_groups[month] = month_groups[month] or {}
		table.insert(month_groups[month], task)
	end

	local store = module.get("store")
	if not store then
		return false, "无法获取存储模块", 0
	end

	local archived_count = 0
	local deleted_code_markers = 0

	-- 按月份处理归档
	for month, month_tasks in pairs(month_groups) do
		local insert_pos, is_new = find_or_create_archive_section(lines, month)

		-- 构建归档任务行
		local archive_lines = {}
		for _, task in ipairs(month_tasks) do
			local indent = string.rep("  ", task.level or 0)
			local task_line = indent .. "- [x] " .. (task.content or "")

			if task.id then
				task_line = task_line .. " {#" .. task.id .. "}"
			end

			table.insert(archive_lines, task_line)
		end

		-- 在归档区域插入任务
		for i, line in ipairs(archive_lines) do
			table.insert(lines, insert_pos + i - 1, line)
		end

		-- 处理每个任务
		for _, task in ipairs(month_tasks) do
			if task.id then
				if safe_delete_code_marker(store, task.id) then
					deleted_code_markers = deleted_code_markers + 1
				end

				if safe_archive_store_record(store, task.id) then
					archived_count = archived_count + 1
				end
			end
		end
	end

	-- 从原位置删除任务
	for _, task in ipairs(tasks) do
		table.remove(lines, task.line_num)
	end

	-- 写回文件
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- 清理解析器缓存
	local parser_mod = module.get("core.parser")
	if parser_mod then
		parser_mod.clear_cache(path)
	end

	-- 刷新UI
	local ui_mod = module.get("ui")
	if ui_mod and ui_mod.refresh then
		ui_mod.refresh(bufnr, false)
	end

	return true,
		string.format("成功归档 %d 个任务，删除 %d 个代码标记", archived_count, deleted_code_markers),
		archived_count
end

---------------------------------------------------------------------
-- 一键归档入口函数
---------------------------------------------------------------------

--- 一键归档已完成任务
function M.archive_completed_tasks(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local archivable_tasks = M.get_archivable_tasks(bufnr)

	if #archivable_tasks == 0 then
		return false, "没有可归档的任务", 0
	end

	local confirm = vim.fn.confirm(
		string.format(
			"确定要归档 %d 个已完成任务吗？\n这将删除代码中的TODO标记。",
			#archivable_tasks
		),
		"&Yes\n&No",
		2
	)

	if confirm ~= 1 then
		return false, "取消归档", 0
	end

	return M.archive_tasks(bufnr, archivable_tasks)
end

return M
