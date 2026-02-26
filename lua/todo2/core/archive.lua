-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- 重构版：支持树完整性检查，彻底分离双链任务和普通任务

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local types = require("todo2.store.types")
local tag_manager = require("todo2.utils.tag_manager")
local store = require("todo2.store")
local deleter = require("todo2.task.deleter")
local events = require("todo2.core.events")

---------------------------------------------------------------------
-- 文件操作辅助函数
---------------------------------------------------------------------
local function ensure_written(path)
	local bufnr = vim.fn.bufnr(path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		if vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
			pcall(vim.api.nvim_buf_call, bufnr, function()
				vim.cmd("silent write")
			end)
		end
	end
end

---------------------------------------------------------------------
-- 归档配置
---------------------------------------------------------------------
local ARCHIVE_CONFIG = {
	ARCHIVE_SECTION_PREFIX = "## Archived",
	DATE_FORMAT = "%Y-%m",
}

---------------------------------------------------------------------
-- 检测归档区域
---------------------------------------------------------------------
local function detect_archive_sections(lines)
	local sections = {}
	local current_section = nil

	for i, line in ipairs(lines) do
		if line:match("^## Archived %(%d%d%d%d%-%d%d%)") then
			if current_section then
				current_section.end_line = i - 1
				table.insert(sections, current_section)
			end
			current_section = {
				start_line = i,
				month = line:match("%((%d%d%d%d%-%d%d)%)"),
			}
		elseif current_section and line:match("^## ") then
			current_section.end_line = i - 1
			table.insert(sections, current_section)
			current_section = nil
		end
	end

	if current_section then
		current_section.end_line = #lines
		table.insert(sections, current_section)
	end

	return sections
end

--- 检查任务是否已在归档区域
local function is_task_in_archive_sections(task, archive_sections)
	if not task or not task.line_num then
		return false
	end

	for _, section in ipairs(archive_sections) do
		if task.line_num >= section.start_line and task.line_num <= section.end_line then
			return true
		end
	end

	return false
end

---------------------------------------------------------------------
-- ⭐ 树完整性检查（核心规则）
---------------------------------------------------------------------

--- 检查整个任务树是否都可归档（所有任务都已完成）
--- @param task table 根任务
--- @return boolean, string|nil 是否可归档，原因
local function is_task_tree_archivable(task)
	if not task then
		return false, "任务不存在"
	end

	-- 检查当前任务是否已完成
	if not types.is_completed_status(task.status) then
		return false, string.format("任务 '%s' 未完成", task.content or "未知")
	end

	-- 递归检查所有子任务
	if task.children then
		for _, child in ipairs(task.children) do
			local child_ok, reason = is_task_tree_archivable(child)
			if not child_ok then
				return false, reason
			end
		end
	end

	return true, nil
end

--- 从任务树收集所有节点
--- @param root table 根任务
--- @param result table 收集结果（递归用）
--- @return table 所有节点列表
local function collect_tree_nodes(root, result)
	result = result or {}

	-- 添加当前节点
	table.insert(result, root)

	-- 递归添加子节点
	if root.children then
		for _, child in ipairs(root.children) do
			collect_tree_nodes(child, result)
		end
	end

	return result
end

--- 获取可归档的任务树（只返回整个树都可归档的根任务）
--- @param tasks table 所有任务列表
--- @param roots table 根任务列表
--- @return table 可归档的根任务列表
function M.get_archivable_task_roots(tasks, roots)
	local archivable_roots = {}

	-- 检查每个根任务
	for _, root in ipairs(roots) do
		local ok, reason = is_task_tree_archivable(root)
		if ok then
			table.insert(archivable_roots, root)
		else
			-- 调试信息，不干扰用户
			vim.notify(string.format("跳过任务树: %s", reason), vim.log.levels.DEBUG)
		end
	end

	return archivable_roots
end

---------------------------------------------------------------------
-- 归档算法核心（保持原有逻辑）
---------------------------------------------------------------------
local function check_task_archivable(task)
	if not task then
		return false, {}, "任务不存在"
	end

	if not types.is_completed_status(task.status) then
		return false, {}, string.format("任务 '%s' 未完成", task.content or "未知")
	end

	if not task.children or #task.children == 0 then
		return true, { task }, nil
	end

	local all_children_archivable = true
	local archive_subtree = { task }
	local reasons = {}

	for _, child in ipairs(task.children) do
		local child_archivable, child_subtree, child_reason = check_task_archivable(child)
		if not child_archivable then
			all_children_archivable = false
			table.insert(reasons, child_reason or "子任务不可归档")
		else
			for _, child_task in ipairs(child_subtree) do
				table.insert(archive_subtree, child_task)
			end
		end
	end

	if all_children_archivable then
		return true, archive_subtree, nil
	else
		return false, {}, table.concat(reasons, "\n")
	end
end

---------------------------------------------------------------------
-- 获取可归档任务（兼容旧接口）
---------------------------------------------------------------------
function M.get_archivable_tasks(bufnr, parser, opts)
	opts = opts or {}
	local path = vim.api.nvim_buf_get_name(bufnr)

	if path == "" or not path:match("%.todo%.md$") then
		return {}
	end

	local tasks, roots = parser.parse_file(path, opts.force_refresh)
	if not tasks then
		return {}
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local archive_sections = detect_archive_sections(lines)

	local archivable_tasks = {}
	local visited = {}

	local function dfs(task)
		if visited[task] then
			return
		end
		visited[task] = true

		if is_task_in_archive_sections(task, archive_sections) then
			return
		end

		if not types.is_completed_status(task.status) then
			return
		end

		local archivable, subtree = check_task_archivable(task)
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
-- 收集代码标记快照（只用于双链任务）
---------------------------------------------------------------------
local function collect_code_snapshots(tasks)
	local snapshots = {}

	for _, task in ipairs(tasks) do
		if task.id then
			local code_link = store.link.get_code(task.id, { verify_line = false })
			if code_link then
				local lines = {}
				if vim.fn.filereadable(code_link.path) == 1 then
					lines = vim.fn.readfile(code_link.path)
				end

				snapshots[task.id] = {
					path = code_link.path,
					line = code_link.line,
					content = code_link.content,
					tag = code_link.tag,
					context = code_link.context,
					surrounding_lines = {
						prev = code_link.line > 1 and lines[code_link.line - 1] or "",
						curr = lines[code_link.line] or "",
						next = code_link.line < #lines and lines[code_link.line + 1] or "",
					},
				}
			end
		end
	end

	return snapshots
end

---------------------------------------------------------------------
-- 归档区域管理
---------------------------------------------------------------------
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
-- ⭐ 生成双链任务的归档行
---------------------------------------------------------------------
local function generate_dual_archive_line(task)
	if not task.id then
		return nil
	end

	local tag = tag_manager.get_tag_for_storage(task.id) or "TODO"
	return string.format("%s- [>] {#%s} %s: %s", string.rep("  ", task.level or 0), task.id, tag, task.content or "")
end

---------------------------------------------------------------------
-- ⭐ 生成普通任务的归档行
---------------------------------------------------------------------
local function generate_normal_archive_line(task)
	return string.format("%s- [>] %s", string.rep("  ", task.level or 0), task.content or "")
end

---------------------------------------------------------------------
-- ⭐ 按树形结构生成归档行
---------------------------------------------------------------------
local function generate_tree_archive_lines(root, result)
	result = result or {}

	-- 生成当前任务行
	if root.id then
		table.insert(result, generate_dual_archive_line(root))
	else
		table.insert(result, generate_normal_archive_line(root))
	end

	-- 递归生成子任务
	if root.children then
		table.sort(root.children, function(a, b)
			return a.line_num < b.line_num
		end)
		for _, child in ipairs(root.children) do
			generate_tree_archive_lines(child, result)
		end
	end

	return result
end

---------------------------------------------------------------------
-- ⭐ 核心归档功能（彻底分离两种任务类型，保持树结构）
---------------------------------------------------------------------
function M.archive_tasks(bufnr, tasks, roots, parser)
	if #tasks == 0 then
		return false, "没有可归档的任务", 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" or not path:match("%.todo%.md$") then
		return false, "当前不是TODO文件", 0
	end

	-- =========================================================
	-- 1. 获取可归档的任务树（只取整个树都完成的根任务）
	-- =========================================================
	local archivable_roots = M.get_archivable_task_roots(tasks, roots)

	if #archivable_roots == 0 then
		return false, "没有完整的可归档任务树（存在未完成的子任务）", 0
	end

	-- =========================================================
	-- 2. 从可归档的树收集所有要归档的任务
	-- =========================================================
	local tasks_to_archive = {}
	local root_trees = {} -- 保留树结构用于归档

	for _, root in ipairs(archivable_roots) do
		local tree_nodes = collect_tree_nodes(root)
		for _, node in ipairs(tree_nodes) do
			table.insert(tasks_to_archive, node)
		end
		table.insert(root_trees, root)
	end

	-- 按行号倒序排序（用于后续删除）
	table.sort(tasks_to_archive, function(a, b)
		return a.line_num > b.line_num
	end)

	-- =========================================================
	-- 3. 分离双链任务和普通任务（用于存储层处理）
	-- =========================================================
	local dual_tasks = {} -- 有ID的任务
	local normal_tasks = {} -- 无ID的任务

	for _, task in ipairs(tasks_to_archive) do
		if task.id then
			table.insert(dual_tasks, task)
		else
			table.insert(normal_tasks, task)
		end
	end

	-- =========================================================
	-- 4. 处理双链任务（存储层）
	-- =========================================================
	local archived_ids = {}
	if #dual_tasks > 0 then
		local code_snapshots = collect_code_snapshots(dual_tasks)

		for _, task in ipairs(dual_tasks) do
			if task.id then
				local todo_link = store.link.get_todo(task.id, { verify_line = false })
				if todo_link and not types.is_completed_status(todo_link.status) then
					store.link.mark_completed(task.id)
				end

				local code_snapshot = code_snapshots[task.id]
				store.link.mark_archived(task.id, "归档操作", {
					code_snapshot = code_snapshot,
				})

				table.insert(archived_ids, task.id)
			end
		end

		if deleter then
			for _, task in ipairs(dual_tasks) do
				if task.id and code_snapshots[task.id] then
					deleter.archive_code_link(task.id)
				end
			end
		end
	end

	-- =========================================================
	-- 5. 处理 TODO 文件内容（使用标记重建法删除）
	-- =========================================================
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- 创建要删除的行号集合
	local delete_lines = {}
	for _, task in ipairs(tasks_to_archive) do
		delete_lines[task.line_num] = true
	end

	-- 重建lines，跳过要删除的行
	local new_lines = {}
	for i, line in ipairs(lines) do
		if not delete_lines[i] then
			table.insert(new_lines, line)
		end
	end
	lines = new_lines

	-- =========================================================
	-- 6. 按树形结构插入归档区
	-- =========================================================
	-- 按月份分组（按树组织）
	local month_groups = {}
	for _, root in ipairs(root_trees) do
		local month = os.date(ARCHIVE_CONFIG.DATE_FORMAT)
		if not month_groups[month] then
			month_groups[month] = { trees = {} }
		end
		table.insert(month_groups[month].trees, root)
	end

	local archived_count = 0

	-- 按月份处理
	for month, groups in pairs(month_groups) do
		local insert_pos, is_new = find_or_create_archive_section(lines, month)

		local archive_lines = {}

		-- 按树生成归档行（保持树形结构）
		table.sort(groups.trees, function(a, b)
			return a.line_num < b.line_num -- 保持原有顺序
		end)

		for _, root in ipairs(groups.trees) do
			local tree_lines = generate_tree_archive_lines(root)
			for _, line in ipairs(tree_lines) do
				table.insert(archive_lines, line)
			end
			-- 树之间添加空行分隔
			table.insert(archive_lines, "")
		end

		-- 插入归档行
		for i, line in ipairs(archive_lines) do
			table.insert(lines, insert_pos + i - 1, line)
		end

		archived_count = archived_count + #archive_lines
	end

	-- =========================================================
	-- 7. 写回文件
	-- =========================================================
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	ensure_written(path)

	-- =========================================================
	-- 8. 触发事件（只包含双链任务）
	-- =========================================================
	if events and #archived_ids > 0 then
		events.on_state_changed({
			source = "archive_module",
			ids = archived_ids,
			file = path,
			bufnr = bufnr,
		})
	end

	local summary = string.format(
		"成功归档 %d 个任务树（双链: %d, 普通: %d）",
		#root_trees,
		#dual_tasks,
		#normal_tasks
	)
	vim.notify(summary, vim.log.levels.INFO)

	return true, summary, archived_count
end

---------------------------------------------------------------------
-- 一键归档入口
---------------------------------------------------------------------
function M.archive_completed_tasks(bufnr, parser, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	opts = opts or {}

	local path = vim.api.nvim_buf_get_name(bufnr)
	local tasks, roots = parser.parse_file(path, opts.force_refresh)

	local archivable_roots = M.get_archivable_task_roots(tasks, roots)

	-- 统计信息
	local total_trees = #archivable_roots
	local total_tasks = 0
	for _, root in ipairs(archivable_roots) do
		total_tasks = total_tasks + #collect_tree_nodes(root)
	end

	if total_trees == 0 then
		vim.notify("没有完整的可归档任务树（存在未完成的子任务）", vim.log.levels.INFO)
		return false, "无可归档任务", 0
	end

	local confirm = vim.fn.confirm(
		string.format(
			"发现 %d 个完整的任务树（共 %d 个任务），确定归档吗？",
			total_trees,
			total_tasks
		),
		"&Yes\n&No",
		2
	)

	if confirm ~= 1 then
		return false, "取消归档", 0
	end

	return M.archive_tasks(bufnr, tasks, roots, parser)
end

-- 导出 detect_archive_sections 供 parser 使用
M.detect_archive_sections = detect_archive_sections

return M
