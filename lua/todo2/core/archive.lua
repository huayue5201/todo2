-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- @brief 核心归档模块（整合存储、事件、状态管理）

local M = {}

local store = require("todo2.store")
local types = require("todo2.store.types")
local events = require("todo2.core.events")
local parser = require("todo2.core.parser")
local deleter = require("todo2.task.deleter")
local comment = require("todo2.utils.comment")

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
-- 核心功能 1：归档单个任务
---------------------------------------------------------------------

function M.archive_task(task, opts)
	opts = opts or {}

	if not task then
		return false, "任务不存在", nil
	end

	if not opts.force and not types.is_completed_status(task.status) then
		return false, "任务未完成，不能归档", { reason = "not_completed" }
	end

	local result = {
		id = task.id,
		content = task.content,
		code_deleted = false,
	}

	if task.id and not CONFIG.preserve_code_markers then
		local ok = deleter.archive_code_link(task.id)
		result.code_deleted = ok
	end

	if task.id then
		store.link.mark_archived(task.id, opts.reason or "core_archive")
	end

	return true, "归档成功", result
end

-- 核心功能 2：归档任务组
---------------------------------------------------------------------

function M.archive_task_group(root_task, bufnr, opts)
	opts = opts or {}

	if not root_task or not bufnr then
		return false, "参数错误", nil
	end

	if not opts.force and not is_tree_completed(root_task) then
		return false, "任务组中存在未完成的任务", nil
	end

	local tasks = collect_tree_nodes(root_task)
	local all_ids = {}
	for _, task in ipairs(tasks) do
		if task.id then
			table.insert(all_ids, task.id)
		end
	end

	-- ⭐ 修复：先保存快照（对每个任务调用 mark_archived）
	for _, id in ipairs(all_ids) do
		store.link.mark_archived(id, opts.reason or "archive_group")
	end

	-- 批量物理删除代码标记
	local code_deleted = 0
	if not CONFIG.preserve_code_markers then
		for _, id in ipairs(all_ids) do
			if deleter.archive_code_link(id) then
				code_deleted = code_deleted + 1
			end
		end
	end

	-- 移动文件中的任务行到归档区域
	M._move_to_archive_section(bufnr, tasks)

	local group_result = {
		root_id = root_task.id,
		total_tasks = #tasks,
		archived_tasks = tasks,
		code_deleted_count = code_deleted,
		timestamp = os.time(),
	}

	events.on_state_changed({
		source = "archive_group",
		bufnr = bufnr,
		ids = all_ids,
		file = vim.api.nvim_buf_get_name(bufnr),
		timestamp = os.time() * 1000,
	})

	return true, string.format("归档任务组: %d个任务", #tasks), group_result
end

--- 移动任务到归档区域
function M._move_to_archive_section(bufnr, tasks)
	local path = vim.api.nvim_buf_get_name(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local archive_start = M._find_or_create_archive_section(bufnr, lines)

	table.sort(tasks, function(a, b)
		return a.line_num > b.line_num
	end)

	local lines_to_move = {}
	for _, task in ipairs(tasks) do
		local line = lines[task.line_num]
		if line then
			local archived_line = line:gsub("%[x%]", CONFIG.archive_marker)
			table.insert(lines_to_move, {
				line = archived_line,
				original_line = task.line_num,
			})
		end
	end

	for _, item in ipairs(lines_to_move) do
		vim.api.nvim_buf_set_lines(bufnr, item.original_line - 1, item.original_line, false, {})
	end

	for i, item in ipairs(lines_to_move) do
		vim.api.nvim_buf_set_lines(bufnr, archive_start + i - 1, archive_start + i - 1, false, { item.line })
	end

	parser.invalidate_cache(path)
end

--- 查找或创建归档区域
function M._find_or_create_archive_section(bufnr, lines)
	local archive_title = os.date("## Archived (%Y-%m)")

	for i, line in ipairs(lines) do
		if line:match("^## Archived %(20%d%d%-%d%d%)") then
			return i + 1
		end
	end

	local new_lines = {
		"",
		archive_title,
		"",
	}
	vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_lines)
	return #lines + 2
end

---------------------------------------------------------------------
-- 上下文匹配
---------------------------------------------------------------------
local function find_context_match(lines, context)
	if not lines or #lines == 0 or not context or #context == 0 then
		return nil
	end

	local best_match = nil
	local best_score = 0

	local target_idx = nil
	for i, ctx_line in ipairs(context) do
		if ctx_line.is_target then
			target_idx = i
			break
		end
	end

	if not target_idx then
		return nil
	end

	for i = 1, #lines do
		local match_count = 0
		local total_count = 0

		for j, ctx_line in ipairs(context) do
			local line_idx = i + (j - target_idx)
			if line_idx >= 1 and line_idx <= #lines then
				total_count = total_count + 1
				local line_content = lines[line_idx]:gsub("^%s+", ""):gsub("%s+$", "")
				local ctx_content = ctx_line.content:gsub("^%s+", ""):gsub("%s+$", "")
				if line_content == ctx_content then
					match_count = match_count + 1
				end
			end
		end

		if total_count > 0 then
			local score = match_count / total_count
			if score > best_score and score >= 0.6 then
				best_score = score
				best_match = i + (target_idx - 1)
			end
		end
	end

	return best_match
end

---------------------------------------------------------------------
-- 恢复代码标记
---------------------------------------------------------------------
function M._restore_code_from_snapshot(id, snapshot)
	if not snapshot.code or not snapshot.code.path then
		return false
	end

	local filepath = snapshot.code.path
	local tag = snapshot.code.tag or "TODO"
	local content = snapshot.code.content or ""
	local context = snapshot.code.context

	local bufnr = vim.fn.bufadd(filepath)
	vim.fn.bufload(bufnr)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	for i, line in ipairs(lines) do
		if line:find(":ref:" .. id) or line:find("{%#" .. id .. "%}") then
			vim.notify(
				string.format("代码标记 %s 已存在于行 %d，跳过恢复", id:sub(1, 6), i),
				vim.log.levels.INFO
			)
			return true
		end
	end

	local insert_line = nil

	if context and #context > 0 then
		insert_line = find_context_match(lines, context)
	end

	if not insert_line then
		insert_line = math.min(snapshot.code.line or 1, #lines + 1)
	end

	local code_line
	if content and content ~= "" then
		local prefix = comment.get_prefix(bufnr)
		code_line = string.format("%s %s:ref:%s %s", prefix, tag, id, content)
	else
		code_line = comment.generate_marker(id, tag, bufnr)
	end

	table.insert(lines, insert_line, code_line)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	local link_service = require("todo2.creation.service")
	link_service.create_code_link(bufnr, insert_line, id, content, tag)

	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	local prefix = comment.get_prefix(bufnr)
	vim.notify(
		string.format("已恢复代码标记 %s 到行 %d（%s）", id:sub(1, 6), insert_line, prefix),
		vim.log.levels.INFO
	)

	return true
end

---------------------------------------------------------------------
-- 恢复TODO任务
---------------------------------------------------------------------
function M._restore_todo_from_snapshot(id, snapshot, bufnr)
	if not snapshot.task or not snapshot.task.path then
		return false
	end

	local filepath = snapshot.task.path
	local line_num = snapshot.task.line_num
	local status = snapshot.task.status
	local content = snapshot.task.content
	local tag = snapshot.task.tag or "TODO"
	local level = snapshot.task.level or 0
	local indent = string.rep("  ", level)

	local todo_bufnr = bufnr
	if not todo_bufnr or todo_bufnr == 0 then
		todo_bufnr = vim.fn.bufadd(filepath)
		vim.fn.bufload(todo_bufnr)
	end

	local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)

	for i, line in ipairs(lines) do
		if line:match("{%#" .. id .. "%}") then
			vim.notify(
				string.format("TODO任务 %s 已存在于行 %d，跳过恢复", id:sub(1, 6), i),
				vim.log.levels.INFO
			)
			return true
		end
	end

	local insert_line = math.min(line_num, #lines + 1)

	local checkbox
	if status == types.STATUS.COMPLETED then
		checkbox = "[x]"
	elseif status == types.STATUS.ARCHIVED then
		checkbox = "[>]"
	else
		checkbox = "[ ]"
	end

	local task_line_parts = {}
	table.insert(task_line_parts, indent)
	table.insert(task_line_parts, "- ")
	table.insert(task_line_parts, checkbox)
	table.insert(task_line_parts, " ")
	if tag and tag ~= "" then
		table.insert(task_line_parts, tag)
		table.insert(task_line_parts, ": ")
	end
	table.insert(task_line_parts, content)
	table.insert(task_line_parts, " {#" .. id .. "}")

	local task_line = table.concat(task_line_parts, "")

	table.insert(lines, insert_line, task_line)
	vim.api.nvim_buf_set_lines(todo_bufnr, 0, -1, false, lines)

	local todo_link = store.link.get_todo(id, { verify_line = false })
	if todo_link then
		if status == types.STATUS.ARCHIVED then
			todo_link.status = types.STATUS.COMPLETED
			todo_link.completed_at = snapshot.task.completed_at or os.time()
		else
			todo_link.status = status
			if status == types.STATUS.COMPLETED then
				todo_link.completed_at = snapshot.task.completed_at or os.time()
			end
		end
		todo_link.line = insert_line
		todo_link.updated_at = os.time()
		store.link.update_todo(id, todo_link)
	end

	local autosave = require("todo2.core.autosave")
	autosave.request_save(todo_bufnr)

	parser.invalidate_cache(filepath)

	vim.notify(
		string.format("已恢复TODO任务 %s 到行 %d（状态: %s）", id:sub(1, 6), insert_line, checkbox),
		vim.log.levels.INFO
	)

	return true
end

---------------------------------------------------------------------
-- 从归档区域移回主区域
---------------------------------------------------------------------
function M._restore_from_archive_section(bufnr, id, snapshot)
	if not snapshot.task or not snapshot.task.line_num then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local archive_start = nil

	for i, line in ipairs(lines) do
		if line:match("^## Archived %(20%d%d%-%d%d%)") then
			archive_start = i
			break
		end
	end

	if not archive_start then
		return
	end

	local task_line_in_archive = nil
	for i = archive_start + 1, #lines do
		if lines[i]:match("{%#" .. id .. "%}") then
			task_line_in_archive = i
			break
		end
	end

	if not task_line_in_archive then
		return
	end

	local task_line = lines[task_line_in_archive]
	table.remove(lines, task_line_in_archive)

	local insert_pos = 1
	for i = 1, #lines do
		if lines[i]:match("^## ") then
			insert_pos = i
			break
		end
	end

	table.insert(lines, insert_pos, task_line)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

---------------------------------------------------------------------
-- 核心功能 3：恢复归档任务
---------------------------------------------------------------------
function M.restore_task(id, bufnr, opts)
	opts = opts or {}

	local snapshot = store.link.get_archive_snapshot(id)
	if not snapshot then
		return false, "找不到归档快照"
	end

	local snapshot_backup = vim.deepcopy(snapshot)

	local success, err = pcall(function()
		M._restore_from_archive_section(bufnr, id, snapshot)
		M._restore_todo_from_snapshot(id, snapshot, bufnr)
		if snapshot.code then
			M._restore_code_from_snapshot(id, snapshot)
		end
	end)

	if not success then
		vim.notify(string.format("恢复失败: %s", tostring(err)), vim.log.levels.ERROR)
		return false, "恢复过程中出错"
	end

	if not opts.keep_snapshot then
		store.link.delete_archive_snapshot(id)
	end

	events.on_state_changed({
		source = "restore_task",
		bufnr = bufnr,
		ids = { id },
		file = vim.api.nvim_buf_get_name(bufnr),
		timestamp = os.time() * 1000,
	})

	return true, string.format("任务 %s 恢复成功", id:sub(1, 6))
end

---------------------------------------------------------------------
-- 核心功能 4：自动归档
---------------------------------------------------------------------
function M.auto_archive(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return { archived = 0 }
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path:match("%.todo%.md$") then
		return { archived = 0 }
	end

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

	for _, task in ipairs(to_archive) do
		M.archive_task(task, { force = true, reason = "auto_archive" })
	end

	return { archived = #to_archive }
end

return M
