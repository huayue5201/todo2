-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- 精简版本：完全依赖 parser 模块，移除 completed 字段

local M = {}

local module = require("todo2.module")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 归档配置
---------------------------------------------------------------------
local ARCHIVE_CONFIG = {
	ARCHIVE_SECTION_PREFIX = "## Archived",
	DATE_FORMAT = "%Y-%m",
}

---------------------------------------------------------------------
-- 依赖权威解析模块
---------------------------------------------------------------------
local function get_parser()
	return module.get("core.parser")
end

---------------------------------------------------------------------
-- 归档算法核心（基于 status）
---------------------------------------------------------------------
--- 检查任务是否可归档（递归检查子树）
local function check_task_archivable(task)
	if not task or not types.is_completed_status(task.status) then
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
		local child_archivable, child_subtree = check_task_archivable(child)
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
-- 获取文件中所有可归档的任务
---------------------------------------------------------------------
function M.get_archivable_tasks(bufnr)
	local parser = get_parser()
	local path = vim.api.nvim_buf_get_name(bufnr)

	if path == "" or not path:match("%.todo%.md$") then
		return {}
	end

	local tasks, roots = parser.parse_file(path)
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
-- ⭐ 生成归档行（统一使用存储层权威标签）
---------------------------------------------------------------------
local function generate_archive_line(task)
	local tag_manager = module.get("todo2.utils.tag_manager")
	local tag = "TODO"

	if task.id and tag_manager then
		-- 获取存储中的权威标签（存储优先）
		tag = tag_manager.get_tag_for_storage(task.id)
	elseif task.tag then
		tag = task.tag
	end

	local archive_task_line =
		string.format("%s- [>] {#%s} %s: %s", string.rep("  ", task.level or 0), task.id or "", tag, task.content or "")
	return archive_task_line
end

---------------------------------------------------------------------
-- ⭐ 核心归档功能（复用 deleter 删除代码标记）
---------------------------------------------------------------------
function M.archive_tasks(bufnr, tasks)
	if #tasks == 0 then
		return false, "没有可归档的任务", 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" or not path:match("%.todo%.md$") then
		return false, "当前不是TODO文件", 0
	end

	-- 1. 归档前确保存储状态同步（标记为归档）
	local store = module.get("store")
	if store and store.link then
		for _, task in ipairs(tasks) do
			if task.id then
				-- 确保任务已完成（如果未完成，先标记完成）
				local todo_link = store.link.get_todo(task.id, { verify_line = false })
				if todo_link and not types.is_completed_status(todo_link.status) then
					store.link.mark_completed(task.id)
				end
				-- 标记为归档
				store.link.mark_archived(task.id, "归档操作")
			end
		end
	end

	-- 2. 读取 TODO 文件内容
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not lines then
		return false, "无法读取文件", 0
	end

	-- 3. 按月份分组任务
	local month_groups = {}
	for _, task in ipairs(tasks) do
		local month = os.date(ARCHIVE_CONFIG.DATE_FORMAT)
		month_groups[month] = month_groups[month] or {}
		table.insert(month_groups[month], task)
	end

	local archived_count = 0

	-- 4. 将任务行插入归档区
	for month, month_tasks in pairs(month_groups) do
		local insert_pos, is_new = find_or_create_archive_section(lines, month)

		local archive_lines = {}
		for _, task in ipairs(month_tasks) do
			table.insert(archive_lines, generate_archive_line(task))
		end

		for i, line in ipairs(archive_lines) do
			table.insert(lines, insert_pos + i - 1, line)
		end

		archived_count = archived_count + #month_tasks
	end

	-- 5. 从原位置删除任务（从下往上删除）
	for _, task in ipairs(tasks) do
		if task.line_num <= #lines then
			table.remove(lines, task.line_num)
		end
	end

	-- 6. 写回 TODO 文件
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- ⭐ 7. 批量删除所有对应任务的代码标记（复用 link.deleter）
	local deleter = module.get("link.deleter")
	if deleter then
		local ids = {}
		for _, task in ipairs(tasks) do
			if task.id then
				table.insert(ids, task.id)
			end
		end
		if #ids > 0 then
			deleter.batch_delete_todo_links(ids, {
				todo_bufnr = bufnr,
				todo_file = path,
			})
		end
	end

	-- 8. 强制刷新 TODO 缓冲区 UI
	local ui = module.get("ui")
	if ui and ui.refresh then
		ui.refresh(bufnr, true) -- 强制重新解析
	end

	-- 9. 刷新所有已打开代码缓冲区的 conceal（保持视觉一致）
	local conceal = module.get("ui.conceal")
	if conceal then
		local all_bufs = vim.api.nvim_list_bufs()
		for _, buf in ipairs(all_bufs) do
			if vim.api.nvim_buf_is_loaded(buf) then
				local name = vim.api.nvim_buf_get_name(buf)
				if name and not name:match("%.todo%.md$") then
					conceal.apply_buffer_conceal(buf)
				end
			end
		end
	end

	-- 10. 清理解析器缓存
	local parser_mod = get_parser()
	if parser_mod then
		parser_mod.clear_cache(path)
	end

	local summary = string.format("成功归档 %d 个任务", archived_count)
	return true, summary, archived_count
end

---------------------------------------------------------------------
-- 一键归档入口函数
---------------------------------------------------------------------
function M.archive_completed_tasks(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local archivable_tasks = M.get_archivable_tasks(bufnr)

	if #archivable_tasks == 0 then
		return false, "没有可归档的任务", 0
	end

	local confirm =
		vim.fn.confirm(string.format("确定要归档 %d 个已完成任务吗？", #archivable_tasks), "&Yes\n&No", 2)

	if confirm ~= 1 then
		return false, "取消归档", 0
	end

	return M.archive_tasks(bufnr, archivable_tasks)
end

---------------------------------------------------------------------
-- 归档统计功能
---------------------------------------------------------------------
function M.get_archive_stats(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local path = vim.api.nvim_buf_get_name(bufnr)

	if path == "" or not path:match("%.todo%.md$") then
		return { total = 0, by_month = {}, recent_months = {} }
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local stats = {
		total = 0,
		by_month = {},
		recent_months = {},
	}

	local current_month = nil
	local current_count = 0

	for _, line in ipairs(lines) do
		local month = line:match("## Archived %((%d%d%d%d%-%d%d)%)")
		if month then
			if current_month then
				stats.by_month[current_month] = current_count
				stats.total = stats.total + current_count
			end
			current_month = month
			current_count = 0
		elseif current_month and line:match("^%s*%- %[>%]") then
			current_count = current_count + 1
		end
	end

	if current_month then
		stats.by_month[current_month] = current_count
		stats.total = stats.total + current_count
	end

	return stats
end

return M
