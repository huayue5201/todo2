-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- 精简版本：完全依赖 parser 模块

local M = {}

local module = require("todo2.module")

---------------------------------------------------------------------
-- 归档配置（不变）
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
-- 归档算法核心（使用 parser 的任务树）
---------------------------------------------------------------------

--- 检查任务是否可归档（递归检查子树）
local function check_task_archivable(task)
	if not task or not task.completed then -- 使用 completed 字段
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
-- 检测归档区域（仅此功能需要保留，因为 parser 不处理归档区域）
---------------------------------------------------------------------
local function detect_archive_sections(lines)
	local sections = {}
	local current_section = nil

	for i, line in ipairs(lines) do
		-- 检测归档区域开始
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
			-- 归档区域结束（遇到新的章节标题）
			current_section.end_line = i - 1
			table.insert(sections, current_section)
			current_section = nil
		end
	end

	-- 处理最后一个归档区域
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
-- 获取文件中所有可归档的任务（完全依赖 parser）
---------------------------------------------------------------------
function M.get_archivable_tasks(bufnr)
	local parser = get_parser()
	local store = module.get("store")
	local path = vim.api.nvim_buf_get_name(bufnr)

	if path == "" or not path:match("%.todo%.md$") then
		return {}
	end

	-- ✅ 使用权威解析器解析文件
	local tasks, roots = parser.parse_file(path)
	if not tasks then
		return {}
	end

	-- 读取原始文件内容，检测归档区域
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local archive_sections = detect_archive_sections(lines)

	-- 收集可归档的任务
	local archivable_tasks = {}
	local visited = {}

	local function dfs(task)
		if visited[task] then
			return
		end
		visited[task] = true

		-- 检查任务是否已在归档区域
		if is_task_in_archive_sections(task, archive_sections) then
			return
		end

		-- 检查任务是否已完成
		if not task.completed then -- 使用 completed 字段
			return
		end

		-- 使用解析器提供的任务树检查归档条件
		local archivable, subtree = check_task_archivable(task)
		if archivable then
			for _, t in ipairs(subtree) do
				archivable_tasks[t] = true
			end
			return
		end

		-- 递归检查子任务
		for _, child in ipairs(task.children) do
			dfs(child)
		end
	end

	-- 遍历所有根任务
	for _, root in ipairs(roots) do
		dfs(root)
	end

	-- 转换为列表
	local result = {}
	for task, _ in pairs(archivable_tasks) do
		table.insert(result, task)
	end

	-- 按行号降序排序，便于从下往上删除
	table.sort(result, function(a, b)
		return a.line_num > b.line_num
	end)

	return result
end

---------------------------------------------------------------------
-- 归档区域管理（不变）
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
-- 核心归档功能（简化版）
---------------------------------------------------------------------
function M.archive_tasks(bufnr, tasks)
	if #tasks == 0 then
		return false, "没有可归档的任务", 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" or not path:match("%.todo%.md$") then
		return false, "当前不是TODO文件", 0
	end

	-- ⭐ 修复点1：归档前确保存储状态同步
	local store = module.get("store")
	if store and store.link then
		for _, task in ipairs(tasks) do
			if task.id then
				-- 确保任务已完成
				local todo_link = store.link.get_todo(task.id, { verify_line = false })
				if todo_link and not todo_link.completed then
					store.link.mark_completed(task.id, "todo")
				end

				-- 标记为归档
				store.link.mark_archived(task.id, "归档操作", "todo")
			end
		end
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

	local archived_count = 0

	-- 按月份处理归档
	for month, month_tasks in pairs(month_groups) do
		local insert_pos, is_new = find_or_create_archive_section(lines, month)

		-- 构建归档任务行（使用解析器提供的任务数据）
		local archive_lines = {}
		for _, task in ipairs(month_tasks) do
			local archive_task_line = string.format(
				"%s- [>] {#%s} %s: %s", -- 使用归档符号 [>]
				string.rep("  ", task.level or 0),
				task.id or "",
				task.tag or "TODO",
				task.content or ""
			)
			table.insert(archive_lines, archive_task_line)
		end

		-- 在归档区域插入任务
		for i, line in ipairs(archive_lines) do
			table.insert(lines, insert_pos + i - 1, line)
		end

		archived_count = archived_count + #month_tasks
	end

	-- 从原位置删除任务（从下往上删除）
	for _, task in ipairs(tasks) do
		if task.line_num <= #lines then
			table.remove(lines, task.line_num)
		end
	end

	-- 写回文件
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- 清理解析器缓存
	local parser_mod = get_parser()
	if parser_mod then
		parser_mod.clear_cache(path)
	end

	return true, string.format("成功归档 %d 个任务", archived_count), archived_count
end

---------------------------------------------------------------------
-- 一键归档入口函数（简化版）
---------------------------------------------------------------------
function M.archive_completed_tasks(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- 获取可归档任务（使用统一的解析器）
	local archivable_tasks = M.get_archivable_tasks(bufnr)

	if #archivable_tasks == 0 then
		return false, "没有可归档的任务", 0
	end

	-- 显示确认对话框
	local confirm =
		vim.fn.confirm(string.format("确定要归档 %d 个已完成任务吗？", #archivable_tasks), "&Yes\n&No", 2)

	if confirm ~= 1 then
		return false, "取消归档", 0
	end

	return M.archive_tasks(bufnr, archivable_tasks)
end

---------------------------------------------------------------------
-- 归档统计功能（简化版）
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

	-- 分析归档区域
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
		elseif current_month and line:match("^%s*%- %[>%]") then -- 归档符号是 [>]
			current_count = current_count + 1
		end
	end

	-- 添加最后一个归档区域
	if current_month then
		stats.by_month[current_month] = current_count
		stats.total = stats.total + current_count
	end

	return stats
end

return M
