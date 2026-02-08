-- 文件位置：lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- @brief 归档系统核心模块（修复重复归档问题和store调用）

local M = {}

---------------------------------------------------------------------
-- 模块导入
---------------------------------------------------------------------
local module = require("todo2.module")
local format = require("todo2.utils.format")

---------------------------------------------------------------------
-- 归档配置
---------------------------------------------------------------------
local ARCHIVE_CONFIG = {
	ARCHIVE_SECTION_PREFIX = "## Archived",
	DATE_FORMAT = "%Y-%m",
}

---------------------------------------------------------------------
-- 归档算法核心（保持不变）
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

---------------------------------------------------------------------
-- 修复：检测归档区域（保持不变）
---------------------------------------------------------------------

--- 检测文件中的归档区域
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

--- 检查任务是否已在存储中归档
local function is_task_archived_in_store(store, task_id)
	if not store or not task_id then
		return false
	end

	-- 检查TODO链接
	local todo_link = store.link and store.link.get_todo(task_id)
	if todo_link and todo_link.archived_at then
		return true
	end

	-- 检查代码链接
	local code_link = store.link and store.link.get_code(task_id)
	if code_link and code_link.archived_at then
		return true
	end

	return false
end

--- 获取文件中所有可归档的任务（修复重复归档）
function M.get_archivable_tasks(bufnr)
	local parser = module.get("core.parser")
	local store = module.get("store")
	local path = vim.api.nvim_buf_get_name(bufnr)

	if path == "" or not path:match("%.todo%.md$") then
		return {}
	end

	-- 读取文件内容
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not lines then
		return {}
	end

	-- 检测归档区域
	local archive_sections = detect_archive_sections(lines)

	-- 解析任务
	local tasks, roots = parser.parse_file(path)
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

		-- 检查任务是否已在存储中归档
		if task.id and store and is_task_archived_in_store(store, task.id) then
			return
		end

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
-- 归档区域管理（保持不变）
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
-- 核心归档功能（更新store调用）
---------------------------------------------------------------------

--- ⭐ 修复：安全删除代码标记行并归档代码链接（使用新store API）
local function safe_delete_and_archive_code_marker(store, task_id)
	local link_mod = store.link
	if not link_mod then
		return false, false -- 没有链接模块，无法处理
	end

	local code_link = link_mod.get_code(task_id)
	if not code_link or not code_link.path or not code_link.line then
		return false, false -- 没有代码链接，无需处理
	end

	-- 删除代码文件中的标记行
	local code_bufnr = vim.fn.bufadd(code_link.path)
	vim.fn.bufload(code_bufnr)

	local code_line = vim.api.nvim_buf_get_lines(code_bufnr, code_link.line - 1, code_link.line, false)[1] or ""

	if not code_line:match(task_id) then
		return false, false -- 代码标记行不匹配
	end

	local delete_success = pcall(function()
		vim.api.nvim_buf_set_lines(code_bufnr, code_link.line - 1, code_link.line, false, {})

		vim.api.nvim_buf_call(code_bufnr, function()
			vim.cmd("noautocmd silent write")
		end)
	end)

	if not delete_success then
		return false, false -- 删除失败
	end

	-- ⭐ 修复：使用新的 store.link.archive_link 函数
	local archive_success = false
	if link_mod.archive_link then
		local link = link_mod.archive_link(task_id, "project_completed")
		archive_success = link ~= nil
	elseif link_mod.safe_archive then
		-- 兼容旧版store
		archive_success = link_mod.safe_archive(task_id, "project_completed")
	end

	return true, archive_success
end

--- ⭐ 修复：安全归档存储记录（使用新store API）
local function safe_archive_store_record(store, task_id)
	local link_mod = store.link
	if not link_mod then
		return false
	end

	-- 优先使用 archive_link 函数
	if link_mod.archive_link then
		local link = link_mod.archive_link(task_id, "project_completed")
		return link ~= nil
	end

	-- 兼容旧版store
	if link_mod.safe_archive then
		return link_mod.safe_archive(task_id, "project_completed")
	end

	return false
end

--- 修复：正确的归档任务函数
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

	-- 获取store模块
	local store = module.get("store")
	if not store or not store.link then
		return false, "无法获取存储模块", 0
	end

	-- 检查任务是否已经被归档
	local tasks_to_archive = {}
	for _, task in ipairs(tasks) do
		if task.id then
			if not is_task_archived_in_store(store, task.id) then
				table.insert(tasks_to_archive, task)
			end
		end
	end

	if #tasks_to_archive == 0 then
		return false, "所有任务都已被归档", 0
	end

	-- 按月份分组任务
	local month_groups = {}
	for _, task in ipairs(tasks_to_archive) do
		local month = os.date(ARCHIVE_CONFIG.DATE_FORMAT)
		month_groups[month] = month_groups[month] or {}
		table.insert(month_groups[month], task)
	end

	local archived_count = 0
	local deleted_code_markers = 0
	local archived_code_links = 0

	-- 按月份处理归档
	for month, month_tasks in pairs(month_groups) do
		local insert_pos, is_new = find_or_create_archive_section(lines, month)

		-- 构建归档任务行
		local archive_lines = {}
		for _, task in ipairs(month_tasks) do
			-- 使用统一的 format.format_task_line 函数
			local archive_task_line = format.format_task_line({
				indent = string.rep("  ", task.level or 0),
				checkbox = "[x]", -- 归档任务都是已完成的
				id = task.id,
				tag = task.tag or "TODO", -- 使用任务中的标签
				content = task.content or "",
			})
			table.insert(archive_lines, archive_task_line)
		end

		-- 在归档区域插入任务
		for i, line in ipairs(archive_lines) do
			table.insert(lines, insert_pos + i - 1, line)
		end

		-- 处理每个任务
		for _, task in ipairs(month_tasks) do
			if task.id then
				-- 删除代码标记行并归档代码链接
				local code_deleted, code_archived = safe_delete_and_archive_code_marker(store, task.id)
				if code_deleted then
					deleted_code_markers = deleted_code_markers + 1
				end
				if code_archived then
					archived_code_links = archived_code_links + 1
				end

				-- 归档TODO链接
				if safe_archive_store_record(store, task.id) then
					archived_count = archived_count + 1
				end
			end
		end
	end

	-- 从原位置删除任务
	table.sort(tasks_to_archive, function(a, b)
		return a.line_num > b.line_num
	end)

	for _, task in ipairs(tasks_to_archive) do
		if task.line_num <= #lines then
			table.remove(lines, task.line_num)
		end
	end

	-- 写回文件
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- 清理解析器缓存
	local parser_mod = module.get("core.parser")
	if parser_mod then
		parser_mod.clear_cache(path)
	end

	-- 触发归档完成事件
	local events_mod = module.get("core.events")
	if events_mod then
		events_mod.on_state_changed({
			source = "archive_complete",
			file = path,
			bufnr = bufnr,
			ids = vim.tbl_map(function(t)
				return t.id
			end, tasks_to_archive),
			timestamp = os.time() * 1000,
		})
	end

	-- 刷新UI
	local ui_mod = module.get("ui")
	if ui_mod and ui_mod.refresh then
		ui_mod.refresh(bufnr, false)
	end

	return true,
		string.format(
			"成功归档 %d 个任务，删除 %d 个代码标记行，归档 %d 个代码链接",
			archived_count,
			deleted_code_markers,
			archived_code_links
		),
		archived_count
end

---------------------------------------------------------------------
-- 归档统计功能（保持不变）
---------------------------------------------------------------------

--- 获取归档统计信息
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
		-- 查找归档区域标题
		local month = line:match("## Archived %((%d%d%d%d%-%d%d)%)")
		if month then
			if current_month then
				stats.by_month[current_month] = current_count
				stats.total = stats.total + current_count
			end
			current_month = month
			current_count = 0
		elseif current_month and line:match("^%s*%- %[x%]") then
			current_count = current_count + 1
		end
	end

	-- 添加最后一个归档区域
	if current_month then
		stats.by_month[current_month] = current_count
		stats.total = stats.total + current_count
	end

	-- 计算最近3个月的统计
	local now = os.time()
	for i = 0, 2 do
		local month = os.date("%Y-%m", now - i * 30 * 86400)
		stats.recent_months[month] = stats.by_month[month] or 0
	end

	return stats
end

--- 获取存储中的归档统计
function M.get_storage_archive_stats(days)
	local store = module.get("store")
	if not store or not store.link then
		return { total = 0, todo = 0, code = 0 }
	end

	local link_mod = store.link
	local archived = link_mod.get_archived_links(days)
	local stats = {
		total = 0,
		todo = 0,
		code = 0,
		complete_pairs = 0,
		incomplete_pairs = 0,
	}

	for id, data in pairs(archived) do
		if data.todo then
			stats.todo = stats.todo + 1
		end
		if data.code then
			stats.code = stats.code + 1
		end
		if data.todo and data.code then
			stats.complete_pairs = stats.complete_pairs + 1
		elseif data.todo or data.code then
			stats.incomplete_pairs = stats.incomplete_pairs + 1
		end
	end

	stats.total = stats.todo + stats.code

	return stats
end

---------------------------------------------------------------------
-- 一键归档入口函数（保持不变）
---------------------------------------------------------------------

--- 一键归档已完成任务（修复重复归档）
function M.archive_completed_tasks(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- 获取可归档任务（已经过滤掉已归档的任务）
	local archivable_tasks = M.get_archivable_tasks(bufnr)

	if #archivable_tasks == 0 then
		return false, "没有可归档的任务", 0
	end

	-- 显示即将归档的任务信息
	local task_list = ""
	local code_files = {}
	local store = module.get("store")

	for i, task in ipairs(archivable_tasks) do
		if i <= 5 then -- 只显示前5个任务
			task_list = task_list .. string.format("  - %s\n", task.content or "未知任务")
		end

		-- 收集代码文件信息
		if task.id and store and store.link then
			local code_link = store.link.get_code(task.id)
			if code_link and code_link.path then
				local short_path = vim.fn.fnamemodify(code_link.path, ":~:.")
				code_files[short_path] = (code_files[short_path] or 0) + 1
			end
		end
	end

	if #archivable_tasks > 5 then
		task_list = task_list .. string.format("  和其他 %d 个任务...\n", #archivable_tasks - 5)
	end

	-- 显示受影响的代码文件
	local file_list = ""
	if next(code_files) then
		file_list = "\n影响的代码文件:\n"
		for file, count in pairs(code_files) do
			file_list = file_list .. string.format("  - %s (%d 个标记)\n", file, count)
		end
	end

	local confirm = vim.fn.confirm(
		string.format(
			"确定要归档 %d 个已完成任务吗？\n\n即将归档的任务:\n%s%s\n这将删除代码中的TODO标记行，但保留完整的双链数据。",
			#archivable_tasks,
			task_list,
			file_list
		),
		"&Yes\n&No",
		2
	)

	if confirm ~= 1 then
		return false, "取消归档", 0
	end

	return M.archive_tasks(bufnr, archivable_tasks)
end

--- 清理旧归档（按月份）
--- @param months_to_keep number 保留最近几个月的归档
function M.cleanup_old_archives(bufnr, months_to_keep)
	months_to_keep = months_to_keep or 6
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not lines then
		return false, "无法读取文件", 0
	end

	local cutoff_date = os.date("%Y-%m", os.time() - months_to_keep * 30 * 86400)
	local sections_to_remove = {}
	local removed_count = 0

	-- 查找需要删除的归档区域
	local current_section_start = nil
	local current_section_month = nil

	for i, line in ipairs(lines) do
		local month = line:match("## Archived %((%d%d%d%d%-%d%d)%)")
		if month then
			-- 保存上一个区域
			if current_section_start and current_section_month and current_section_month < cutoff_date then
				table.insert(sections_to_remove, {
					start = current_section_start,
					month = current_section_month,
				})
			end

			current_section_start = i
			current_section_month = month
		elseif current_section_start and (line:match("^## ") or i == #lines) then
			-- 区域结束
			if current_section_month and current_section_month < cutoff_date then
				local end_line = line:match("^## ") and i - 1 or i
				table.insert(sections_to_remove, {
					start = current_section_start,
					end_line = end_line,
					month = current_section_month,
				})
			end
			current_section_start = nil
			current_section_month = nil
		end
	end

	-- 从后往前删除区域
	table.sort(sections_to_remove, function(a, b)
		return a.start > b.start
	end)

	for _, section in ipairs(sections_to_remove) do
		local start_line = section.start
		local end_line = section.end_line or start_line

		-- 计算该区域的任务数量
		for i = start_line, end_line do
			if lines[i] and lines[i]:match("^%s*%- %[x%]") then
				removed_count = removed_count + 1
			end
		end

		-- 删除区域
		for _ = start_line, end_line do
			table.remove(lines, start_line)
		end
	end

	if #sections_to_remove > 0 then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		return true,
			string.format("清理了 %d 个旧归档区域，共 %d 个任务", #sections_to_remove, removed_count),
			removed_count
	else
		return false, "没有需要清理的旧归档", 0
	end
end

return M
