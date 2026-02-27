-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- @brief 核心归档模块（整合存储、事件、状态管理）

local M = {}

local store = require("todo2.store")
local types = require("todo2.store.types")
local events = require("todo2.core.events")
local parser = require("todo2.core.parser")
local state_manager = require("todo2.core.state_manager")
local deleter = require("todo2.task.deleter")
local status = require("todo2.core.status")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	archive_marker = "[>]",
	auto_archive_days = 7, -- 自动归档阈值
	preserve_code_markers = false, -- 归档时是否保留代码标记
}

function M.set_config(config)
	CONFIG = vim.tbl_extend("force", CONFIG, config or {})
end

---------------------------------------------------------------------
-- 内部工具函数（复用 parser 的 LRU 缓存）
---------------------------------------------------------------------

--- 收集任务树所有节点
local function collect_tree_nodes(root, result)
	result = result or {}
	table.insert(result, root)
	if root.children then
		for _, child in ipairs(root.children) do
			collect_tree_nodes(child, result)
		end
	end
	return result
end

--- 检查任务树是否全部完成（使用存储层权威状态）
local function is_tree_completed(root)
	local function check(task)
		-- 从存储层获取权威状态
		local todo_link = task.id and store.link.get_todo(task.id, { verify_line = false })
		local status = todo_link and todo_link.status or task.status

		if not types.is_completed_status(status) then
			return false
		end
		if task.children then
			for _, child in ipairs(task.children) do
				if not check(child) then
					return false
				end
			end
		end
		return true
	end
	return check(root)
end

---------------------------------------------------------------------
-- 核心功能 1：归档单个任务（整合 core.status）
---------------------------------------------------------------------

--- 归档单个任务
--- @param task table 任务对象
--- @param opts table 选项
--- @return boolean, string, table
function M.archive_task(task, opts)
	opts = opts or {}

	if not task then
		return false, "任务不存在", nil
	end

	-- 业务规则检查：复用 core.status 的状态流转规则
	if not opts.force and not types.is_completed_status(task.status) then
		return false, "任务未完成，不能归档", { reason = "not_completed" }
	end

	local result = {
		id = task.id,
		content = task.content,
		code_deleted = false,
	}

	-- 处理代码标记（使用 deleter 的物理删除）
	if task.id and not CONFIG.preserve_code_markers then
		-- deleter.archive_code_link 已优化：物理删除 + 标记归档
		local ok = deleter.archive_code_link(task.id)
		result.code_deleted = ok
	end

	-- 更新存储状态（使用 store.link 的纯状态变更）
	if task.id then
		-- 保存归档快照
		local snapshot = {
			task = {
				id = task.id,
				content = task.content,
				status = task.status,
				level = task.level,
				indent = task.indent,
				created_at = task.created_at,
				completed_at = task.completed_at,
			},
			has_code = result.code_deleted,
		}
		store.link.save_archive_snapshot(task.id, snapshot)

		-- 标记为归档（纯状态变更）
		store.link.mark_archived(task.id, opts.reason or "core_archive")
	end

	return true, "归档成功", result
end

---------------------------------------------------------------------
-- 核心功能 2：归档任务组（整合 state_manager 的批量操作）
---------------------------------------------------------------------

--- 归档任务组
--- @param root_task table 根任务
--- @param bufnr number 缓冲区
--- @param opts table 选项
--- @return boolean, string, table
function M.archive_task_group(root_task, bufnr, opts)
	opts = opts or {}

	if not root_task or not bufnr then
		return false, "参数错误", nil
	end

	-- 业务规则检查
	if not opts.force and not is_tree_completed(root_task) then
		return false, "任务组中存在未完成的任务", nil
	end

	-- 收集所有任务
	local tasks = collect_tree_nodes(root_task)

	-- 使用 state_manager 的批量操作机制
	local all_ids = {}
	for _, task in ipairs(tasks) do
		if task.id then
			table.insert(all_ids, task.id)
		end
	end

	-- 批量更新状态（触发 state_manager 的批处理队列）
	local batch_result = status.batch_update( -- ✅ 存在
		all_ids,
		types.STATUS.ARCHIVED,
		"archive_group"
	)

	-- 批量物理删除代码标记
	local code_deleted = 0
	if not CONFIG.preserve_code_markers then
		for _, id in ipairs(all_ids) do
			if deleter.archive_code_link(id) then
				code_deleted = code_deleted + 1
			end
		end
	end

	-- 移动文件中的任务行到归档区域（物理操作）
	M._move_to_archive_section(bufnr, tasks)

	local group_result = {
		root_id = root_task.id,
		total_tasks = #tasks,
		archived_tasks = tasks,
		code_deleted_count = code_deleted,
		timestamp = os.time(),
	}

	-- 触发批量事件（events 已支持批量）
	events.on_state_changed({
		source = "archive_group",
		bufnr = bufnr,
		ids = all_ids,
		file = vim.api.nvim_buf_get_name(bufnr),
		timestamp = os.time() * 1000,
	})

	return true, string.format("归档任务组: %d个任务", #tasks), group_result
end

--- 移动任务到归档区域（内部实现）
function M._move_to_archive_section(bufnr, tasks)
	-- 使用 parser 的缓存获取文件内容
	local path = vim.api.nvim_buf_get_name(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- 查找或创建归档区域
	local archive_start = M._find_or_create_archive_section(bufnr, lines)

	-- 按行号降序排序
	table.sort(tasks, function(a, b)
		return a.line_num > b.line_num
	end)

	-- 收集要移动的行
	local lines_to_move = {}
	for _, task in ipairs(tasks) do
		local line = lines[task.line_num]
		if line then
			-- 将 [x] 改为 [>]
			local archived_line = line:gsub("%[x%]", CONFIG.archive_marker)
			table.insert(lines_to_move, {
				line = archived_line,
				original_line = task.line_num,
			})
		end
	end

	-- 从后往前删除原行
	for _, item in ipairs(lines_to_move) do
		vim.api.nvim_buf_set_lines(bufnr, item.original_line - 1, item.original_line, false, {})
	end

	-- 插入归档行
	for i, item in ipairs(lines_to_move) do
		vim.api.nvim_buf_set_lines(bufnr, archive_start + i - 1, archive_start + i - 1, false, { item.line })
	end

	-- 使解析器缓存失效
	parser.invalidate_cache(path)
end

--- 查找或创建归档区域
function M._find_or_create_archive_section(bufnr, lines)
	local archive_title = os.date("## Archived (%Y-%m)")

	for i, line in ipairs(lines) do
		if line:match("^## Archived %(20%d%d%-%d%d%)") then
			return i + 1 -- 返回标题下一行（内容开始）
		end
	end

	-- 创建新的归档区域
	local new_lines = {
		"",
		archive_title,
		"",
	}
	vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_lines)
	return #lines + 2 -- 返回内容开始行
end

---------------------------------------------------------------------
-- 核心功能 3：恢复归档任务（整合 store.snapshot）
---------------------------------------------------------------------

--- 恢复归档任务
--- @param id string 任务ID
--- @param bufnr number 缓冲区
--- @param opts table 选项
--- @return boolean, string
function M.restore_task(id, bufnr, opts)
	opts = opts or {}

	local snapshot = store.link.get_archive_snapshot(id)
	if not snapshot then
		return false, "找不到归档快照"
	end

	-- 从归档区域移回主区域
	M._restore_from_archive_section(bufnr, id, snapshot)

	-- 恢复代码标记（如果需要）
	if snapshot.has_code then
		-- 使用 deleter 恢复（需实现 restore_code_link）
		-- deleter.restore_code_link(id)
	end

	-- 恢复任务状态
	store.link.unarchive_link(id, { delete_snapshot = not opts.keep_snapshot })

	-- 触发事件
	events.on_state_changed({
		source = "restore_task",
		bufnr = bufnr,
		ids = { id },
		file = vim.api.nvim_buf_get_name(bufnr),
		timestamp = os.time() * 1000,
	})

	return true, "恢复成功"
end

---------------------------------------------------------------------
-- 核心功能 4：自动归档（整合 stats 和 events）
---------------------------------------------------------------------

--- 自动归档过期任务
--- @param bufnr number 缓冲区
--- @return table
function M.auto_archive(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return { archived = 0 }
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path:match("%.todo%.md$") then
		return { archived = 0 }
	end

	-- 使用 stats 模块获取完成状态
	local stats = require("todo2.core.stats")
	local tasks, roots = parser.parse_file(path, false)

	local now = os.time()
	local cutoff = now - CONFIG.auto_archive_days * 86400
	local to_archive = {}

	for _, root in ipairs(roots) do
		local function collect_old_completed(node)
			local todo_link = node.id and store.link.get_todo(node.id, { verify_line = false })
			local status = todo_link and todo_link.status or node.status

			if status == types.STATUS.COMPLETED then
				local completed_at = todo_link and todo_link.completed_at or node.completed_at or 0
				if completed_at <= cutoff then
					table.insert(to_archive, node)
				end
			end

			if node.children then
				for _, child in ipairs(node.children) do
					collect_old_completed(child)
				end
			end
		end
		collect_old_completed(root)
	end

	if #to_archive == 0 then
		return { archived = 0 }
	end

	-- 批量归档
	for _, task in ipairs(to_archive) do
		M.archive_task(task, { force = true, reason = "auto_archive" })
	end

	return { archived = #to_archive }
end

---------------------------------------------------------------------
-- UI辅助（复用 parser 缓存）
---------------------------------------------------------------------

function M.preview_archive(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	-- parser 自动使用 LRU 缓存
	local tasks, roots = parser.parse_file(path, false)

	local preview = {
		total_groups = 0,
		total_tasks = 0,
		groups = {},
	}

	for _, root in ipairs(roots) do
		local completed = is_tree_completed(root)
		local tasks_in_group = collect_tree_nodes(root)

		preview.total_tasks = preview.total_tasks + #tasks_in_group

		table.insert(preview.groups, {
			root = root,
			completed = completed,
			task_count = #tasks_in_group,
			can_archive = completed,
		})

		if completed then
			preview.total_groups = preview.total_groups + 1
		end
	end

	return preview
end

return M
