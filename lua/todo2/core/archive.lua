-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- @brief 核心归档模块（依赖 scheduler，不再直接读文件或调用 parser）

local M = {}

local store = require("todo2.store")
local types = require("todo2.store.types")
local events = require("todo2.core.events")
local scheduler = require("todo2.render.scheduler") -- ⭐ 改：依赖 scheduler
local deleter = require("todo2.task.deleter")
local comment = require("todo2.utils.comment")
local id_utils = require("todo2.utils.id")
local config = require("todo2.config")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	archive_marker = "[>]",
	auto_archive_days = 7,
	preserve_code_markers = false,
}

function M.set_config(user_config)
	CONFIG = vim.tbl_extend("force", CONFIG, user_config or {})
end

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------

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
-- ⭐ 改：使用 scheduler.get_file_lines
---------------------------------------------------------------------

function M._is_task_in_archive(task, lines)
	if not task or not task.line_num then
		return false, nil
	end

	if not lines then
		if not task.path then
			return false, nil
		end
		lines = scheduler.get_file_lines(task.path) -- ⭐ 改
	end

	if not lines or #lines == 0 then
		return false, nil
	end

	for i = task.line_num, 1, -1 do
		if lines[i] and config.is_archive_section_line(lines[i]) then
			return true, i
		end
	end

	return false, nil
end

function M._get_archive_range(lines, archive_start_line)
	if not lines or #lines == 0 or not archive_start_line then
		return archive_start_line, archive_start_line
	end

	local end_line = #lines
	for i = archive_start_line + 1, #lines do
		if lines[i]:match("^## ") and not config.is_archive_section_line(lines[i]) then
			end_line = i - 1
			break
		end
	end

	return archive_start_line, end_line
end

---------------------------------------------------------------------
-- ⭐ 改：构建层级树（保持不变）
---------------------------------------------------------------------

function M._build_task_hierarchy(tasks)
	local task_map = {}
	local roots = {}

	for _, task in ipairs(tasks) do
		task_map[task.id] = {
			task = task,
			children = {},
			level = task.level or 0,
			line_num = task.line_num,
		}
	end

	for _, node in pairs(task_map) do
		if node.task.parent and task_map[node.task.parent.id] then
			table.insert(task_map[node.task.parent.id].children, node)
		else
			table.insert(roots, node)
		end
	end

	local function sort_by_line(a, b)
		return a.line_num < b.line_num
	end
	table.sort(roots, sort_by_line)
	for _, node in pairs(task_map) do
		table.sort(node.children, sort_by_line)
	end

	return roots
end

function M._collect_lines_to_move(roots, lines)
	local result = {}

	local function collect(node)
		local line = lines[node.task.line_num]
		if not line then
			return
		end

		local archived_line = line:gsub("%[x%]", CONFIG.archive_marker):gsub("%[ %]", CONFIG.archive_marker)

		table.insert(result, {
			line = archived_line,
			original_line = node.task.line_num,
			id = node.task.id,
			level = node.level,
			parent_id = node.task.parent and node.task.parent.id,
			line_num = node.task.line_num,
		})

		if #node.children > 0 then
			table.sort(node.children, function(a, b)
				return a.line_num < b.line_num
			end)
			for _, child in ipairs(node.children) do
				collect(child)
			end
		end
	end

	table.sort(roots, function(a, b)
		return a.line_num < b.line_num
	end)

	for _, root in ipairs(roots) do
		collect(root)
	end

	return result
end

---------------------------------------------------------------------
-- ⭐ 改：查找/创建归档区域（使用 scheduler.get_file_lines）
---------------------------------------------------------------------

function M._find_or_create_archive_section(bufnr, lines)
	local archive_title = config.generate_archive_title()

	for i = 1, #lines do
		if config.is_archive_section_line(lines[i]) then
			local insert_point = i + 1
			while insert_point <= #lines and lines[insert_point] ~= "" do
				insert_point = insert_point + 1
			end
			return insert_point, lines
		end
	end

	if not config.is_archive_auto_create() then
		return nil, lines
	end

	local new_lines = {
		"",
		archive_title,
		"",
	}

	for _, line in ipairs(new_lines) do
		table.insert(lines, line)
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return #lines - 1, lines
end

---------------------------------------------------------------------
-- ⭐ 改：移动任务到归档区域（使用 scheduler.get_file_lines）
---------------------------------------------------------------------

function M._move_tasks_to_archive(bufnr, tasks_to_move, archive_start, lines)
	table.sort(tasks_to_move, function(a, b)
		return a.original_line > b.original_line
	end)

	for _, item in ipairs(tasks_to_move) do
		table.remove(lines, item.original_line)
	end

	table.sort(tasks_to_move, function(a, b)
		return a.original_line < b.original_line
	end)

	local insert_pos = archive_start
	for _, item in ipairs(tasks_to_move) do
		if item.original_line < archive_start then
			insert_pos = insert_pos - 1
		end
	end

	for i, item in ipairs(tasks_to_move) do
		local current_pos = insert_pos + i - 1
		table.insert(lines, current_pos, item.line)
		item.new_line_num = current_pos
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return tasks_to_move
end

function M._update_task_lines(tasks_to_move)
	for _, item in ipairs(tasks_to_move) do
		if item.id then
			local link = store.link.get_todo(item.id, { verify_line = false })
			if link then
				link.line = item.new_line_num
				link.updated_at = os.time()
				store.link.update_todo(item.id, link)
			end
		end
	end
end

---------------------------------------------------------------------
-- ⭐ 核心功能：归档任务组（依赖 scheduler）
---------------------------------------------------------------------

function M.archive_task_group(root_task, bufnr, opts)
	opts = opts or {}

	if not root_task or not bufnr then
		return false, "参数错误", nil
	end

	if not opts.force and not is_tree_completed(root_task) then
		return false, "任务组中存在未完成的任务", nil
	end

	-- ⭐ 改：使用 scheduler.get_file_lines
	local path = vim.api.nvim_buf_get_name(bufnr)
	local lines = scheduler.get_file_lines(path, true)

	local in_archive, archive_start = M._is_task_in_archive(root_task, lines)
	if in_archive then
		return false, "任务已在归档区域", nil
	end

	local tasks = collect_tree_nodes(root_task)
	local all_ids = {}
	for _, task in ipairs(tasks) do
		if task.id then
			table.insert(all_ids, task.id)
		end
	end

	local roots = M._build_task_hierarchy(tasks)
	local tasks_to_move = M._collect_lines_to_move(roots, lines)
	if #tasks_to_move == 0 then
		return false, "没有可归档的任务", nil
	end

	local archive_pos, updated_lines = M._find_or_create_archive_section(bufnr, lines)
	if not archive_pos then
		return false, "无法创建归档区域", nil
	end

	tasks_to_move = M._move_tasks_to_archive(bufnr, tasks_to_move, archive_pos, updated_lines)

	for _, id in ipairs(all_ids) do
		store.link.mark_archived(id, "archive_group")
	end

	M._update_task_lines(tasks_to_move)

	local code_deleted = 0
	if not CONFIG.preserve_code_markers then
		for _, id in ipairs(all_ids) do
			if deleter.archive_code_link(id) then
				code_deleted = code_deleted + 1
			end
		end
	end

	events.on_state_changed({
		source = "archive_group",
		bufnr = bufnr,
		ids = all_ids,
		file = path,
		timestamp = os.time() * 1000,
	})

	-- ⭐ 改：不再调用 parser.invalidate_cache
	scheduler.invalidate_cache(path)

	local group_result = {
		root_id = root_task.id,
		total_tasks = #tasks,
		archived_tasks = tasks,
		code_deleted_count = code_deleted,
		timestamp = os.time(),
	}

	return true, string.format("归档任务组: %d个任务", #tasks), group_result
end

---------------------------------------------------------------------
-- ⭐ 其余恢复函数保持不变，只把 readfile/buf_get_lines 改成 scheduler.get_file_lines
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

	local lines = scheduler.get_file_lines(filepath, true) -- ⭐ 改

	for i, line in ipairs(lines) do
		if
			(id_utils.contains_code_mark(line) and id_utils.extract_id_from_code_mark(line) == id)
			or (id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id)
		then
			return true
		end
	end

	local insert_line = nil
	if context and #context > 0 then
		insert_line = nil
	end

	if not insert_line then
		insert_line = math.min(snapshot.code.line or 1, #lines + 1)
	end

	local prefix = comment.get_prefix(bufnr)
	local code_line = string.format("%s %s", prefix, id_utils.format_code_mark(tag, id))
	if content and content ~= "" then
		code_line = code_line .. " " .. content
	end

	table.insert(lines, insert_line, code_line)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	local link_service = require("todo2.creation.service")
	link_service.create_code_link(bufnr, insert_line, id, content, tag)

	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	return true
end

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

	local lines = scheduler.get_file_lines(filepath, true) -- ⭐ 改

	for i, line in ipairs(lines) do
		if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id then
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

	local task_line = string.format(
		"%s- %s %s%s %s",
		indent,
		checkbox,
		tag ~= "" and (tag .. ": ") or "",
		content,
		id_utils.format_todo_anchor(id)
	)

	table.insert(lines, insert_line, task_line)
	vim.api.nvim_buf_set_lines(todo_bufnr, 0, -1, false, lines)

	local todo_link = store.link.get_todo(id, { verify_line = false })
	if todo_link then
		todo_link.status = status
		todo_link.line = insert_line
		todo_link.updated_at = os.time()
		store.link.update_todo(id, todo_link)
	end

	local autosave = require("todo2.core.autosave")
	autosave.request_save(todo_bufnr)

	scheduler.invalidate_cache(filepath) -- ⭐ 改

	return true
end

return M
