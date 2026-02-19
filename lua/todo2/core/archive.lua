-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- 重构版：支持归档撤销 - ⭐ 增强上下文指纹支持

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local types = require("todo2.store.types")
local tag_manager = require("todo2.utils.tag_manager")
local store = require("todo2.store")
local deleter = require("todo2.link.deleter")
local events = require("todo2.core.events")

---------------------------------------------------------------------
-- ⭐ 文件操作辅助函数（替代 file_ops）
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
-- 归档算法核心
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
-- 获取可归档任务
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
-- ⭐ 收集代码标记快照（增强上下文保存）
---------------------------------------------------------------------
local function collect_code_snapshots(tasks)
	local snapshots = {}

	for _, task in ipairs(tasks) do
		if task.id then
			local code_link = store.link.get_code(task.id, { verify_line = false })
			if code_link then
				-- 读取当前文件内容作为快照
				local lines = {}
				if vim.fn.filereadable(code_link.path) == 1 then
					lines = vim.fn.readfile(code_link.path)
				end

				snapshots[task.id] = {
					path = code_link.path,
					line = code_link.line,
					content = code_link.content,
					tag = code_link.tag,
					context = code_link.context, -- ⭐ 保存上下文指纹
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
-- 生成归档行
---------------------------------------------------------------------
local function generate_archive_line(task)
	local tag = "TODO"

	if task.id and tag_manager then
		tag = tag_manager.get_tag_for_storage(task.id)
	elseif task.tag then
		tag = task.tag
	end

	local archive_task_line =
		string.format("%s- [>] {#%s} %s: %s", string.rep("  ", task.level or 0), task.id or "", tag, task.content or "")
	return archive_task_line
end

---------------------------------------------------------------------
-- ⭐ 核心归档功能
---------------------------------------------------------------------
function M.archive_tasks(bufnr, tasks, parser)
	if #tasks == 0 then
		return false, "没有可归档的任务", 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" or not path:match("%.todo%.md$") then
		return false, "当前不是TODO文件", 0
	end

	-- =========================================================
	-- 1. 收集代码标记快照（用于撤销恢复）- ⭐ 包含上下文
	-- =========================================================
	local code_snapshots = collect_code_snapshots(tasks)
	local archived_ids = {}

	-- =========================================================
	-- 2. 归档前确保存储状态同步
	-- =========================================================
	if store and store.link then
		for _, task in ipairs(tasks) do
			if task.id then
				local todo_link = store.link.get_todo(task.id, { verify_line = false })
				if todo_link and not types.is_completed_status(todo_link.status) then
					store.link.mark_completed(task.id)
				end

				-- ⭐ 保存快照并标记为归档（包含上下文）
				local code_snapshot = code_snapshots[task.id]
				store.link.mark_archived(task.id, "归档操作", {
					code_snapshot = code_snapshot,
				})

				table.insert(archived_ids, task.id)
			end
		end
	end

	-- =========================================================
	-- 3. 读取 TODO 文件内容
	-- =========================================================
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not lines then
		return false, "无法读取文件", 0
	end

	-- =========================================================
	-- 4. 按月份分组任务
	-- =========================================================
	local month_groups = {}
	for _, task in ipairs(tasks) do
		local month = os.date(ARCHIVE_CONFIG.DATE_FORMAT)
		month_groups[month] = month_groups[month] or {}
		table.insert(month_groups[month], task)
	end

	local archived_count = 0

	-- =========================================================
	-- 5. 将任务行插入归档区
	-- =========================================================
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

	-- =========================================================
	-- 6. 从原位置删除任务
	-- =========================================================
	table.sort(tasks, function(a, b)
		return a.line_num > b.line_num
	end)

	for _, task in ipairs(tasks) do
		if task.line_num and task.line_num <= #lines then
			table.remove(lines, task.line_num)
		end
	end

	-- =========================================================
	-- 7. 写回 TODO 文件
	-- =========================================================
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	ensure_written(path)

	-- =========================================================
	-- 8. ⭐ 使用归档专用删除（物理删除但保留存储记录）
	-- =========================================================
	if deleter then
		for _, task in ipairs(tasks) do
			if task.id and code_snapshots[task.id] then
				deleter.archive_code_link(task.id)
			end
		end
	end

	-- =========================================================
	-- 9. ⭐ 触发归档事件（统一UI更新）
	-- =========================================================
	if events then
		events.on_state_changed({
			source = "archive_module",
			ids = archived_ids,
			file = path,
			bufnr = bufnr,
		})
	end

	local summary = string.format("成功归档 %d 个任务", archived_count)
	vim.notify(summary, vim.log.levels.INFO)

	return true, summary, archived_count
end

---------------------------------------------------------------------
-- ⭐ 撤销归档功能（增强版：使用上下文指纹）
---------------------------------------------------------------------
--- 撤销归档
--- @param ids string[] 要撤销的任务ID列表
--- @param opts table|nil 选项
---   - use_context: boolean 是否使用上下文定位（默认true）
---   - similarity_threshold: number 相似度阈值（默认70）
--- @return boolean, string
function M.unarchive_tasks(ids, opts)
	opts = opts or {}

	-- ⭐ 是否使用上下文定位（默认开启）
	local use_context = opts.use_context ~= false
	local similarity_threshold = opts.similarity_threshold or 70

	if not ids or #ids == 0 then
		return false, "没有指定要撤销的任务"
	end

	-- 1. 从快照恢复（使用上下文定位）
	local result = store.link.batch_restore_from_snapshots(ids, {
		use_context = use_context,
		similarity_threshold = similarity_threshold,
	})

	-- 2. 收集需要刷新的缓冲区
	local bufs_to_refresh = {}
	local files_to_invalidate = {}

	for _, detail in ipairs(result.details) do
		if detail.success then
			local snapshot = store.link.get_archive_snapshot(detail.id)
			if snapshot then
				-- TODO 文件
				if snapshot.todo and snapshot.todo.path then
					files_to_invalidate[snapshot.todo.path] = true
					local bufnr = vim.fn.bufnr(snapshot.todo.path)
					if bufnr ~= -1 then
						bufs_to_refresh[bufnr] = true
					end
				end

				-- 代码文件
				if snapshot.code and snapshot.code.path then
					files_to_invalidate[snapshot.code.path] = true
					local bufnr = vim.fn.bufnr(snapshot.code.path)
					if bufnr ~= -1 then
						bufs_to_refresh[bufnr] = true
					end
				end
			end
		end
	end

	-- 3. 清理解析器缓存
	local parser = require("todo2.core.parser")
	for file, _ in pairs(files_to_invalidate) do
		parser.invalidate_cache(file)
	end

	-- 4. 触发统一事件刷新
	if events then
		for bufnr, _ in pairs(bufs_to_refresh) do
			if vim.api.nvim_buf_is_valid(bufnr) then
				events.on_state_changed({
					source = "unarchive_complete",
					bufnr = bufnr,
					file = vim.api.nvim_buf_get_name(bufnr),
					ids = ids,
				})
			end
		end
	end

	vim.notify(result.summary, result.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

	return result.failed == 0, result.summary
end

--- 交互式撤销归档
--- @param bufnr number|nil
function M.unarchive_tasks_interactive(bufnr)
	-- 获取所有归档快照
	local snapshots = store.link.get_all_archive_snapshots()

	if #snapshots == 0 then
		vim.notify("没有可撤销的归档任务", vim.log.levels.INFO)
		return
	end

	-- 构建选择列表
	local choices = {}
	for _, s in ipairs(snapshots) do
		local task_desc = string.format(
			"[%s] %s - %s",
			s.id:sub(1, 6),
			(s.todo and s.todo.content or "未知任务"):sub(1, 40),
			os.date("%Y-%m-%d %H:%M", s.archived_at or 0)
		)
		table.insert(choices, {
			text = task_desc,
			id = s.id,
			snapshot = s,
		})
	end

	vim.ui.select(choices, {
		prompt = "📋 选择要撤销归档的任务：",
		format_item = function(item)
			return item.text
		end,
	}, function(choice)
		if choice then
			M.unarchive_tasks({ choice.id })
		end
	end)
end

---------------------------------------------------------------------
-- 一键归档入口
---------------------------------------------------------------------
function M.archive_completed_tasks(bufnr, parser, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	opts = opts or {}

	local archivable_tasks = M.get_archivable_tasks(bufnr, parser, { force_refresh = opts.force_refresh })

	if #archivable_tasks == 0 then
		return false, "没有可归档的任务", 0
	end

	local confirm =
		vim.fn.confirm(string.format("确定要归档 %d 个已完成任务吗？", #archivable_tasks), "&Yes\n&No", 2)

	if confirm ~= 1 then
		return false, "取消归档", 0
	end

	return M.archive_tasks(bufnr, archivable_tasks, parser)
end

-- 导出 detect_archive_sections 供 parser 使用
M.detect_archive_sections = detect_archive_sections

return M
