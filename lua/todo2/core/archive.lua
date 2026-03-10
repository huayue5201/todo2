-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- 可逆归档：移动整棵任务组到归档区域，并支持恢复到原位置

local M = {}

local types = require("todo2.store.types")
local link = require("todo2.store.link")
local scheduler = require("todo2.render.scheduler")
local parser = require("todo2.core.parser")
local events = require("todo2.core.events")
local id_utils = require("todo2.utils.id")
local comment = require("todo2.utils.comment")
local config = require("todo2.config")
local utils = require("todo2.core.utils")

---------------------------------------------------------------------
-- 文件读写工具
---------------------------------------------------------------------
local function read_file_lines(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	return ok and lines or {}
end

local function write_file_lines(path, lines)
	pcall(vim.fn.writefile, lines, path)
end

---------------------------------------------------------------------
-- 禁止多 ID 行
---------------------------------------------------------------------
local function line_has_multiple_ids(line)
	local ids = {}
	for id in line:gmatch(id_utils.TODO_ANCHOR_PATTERN) do
		table.insert(ids, id)
	end
	return #ids > 1, ids
end

---------------------------------------------------------------------
-- 删除整行代码标记
---------------------------------------------------------------------
local function delete_entire_code_line(id)
	local code_link = link.get_code(id, { verify_line = false })
	if not code_link or not code_link.path or not code_link.line then
		return
	end

	local path = code_link.path
	local line_num = code_link.line
	local lines = read_file_lines(path)

	if line_num <= #lines then
		table.remove(lines, line_num)
		write_file_lines(path, lines)
		link.shift_lines(path, line_num, -1, { skip_archived = false })
	end
end

---------------------------------------------------------------------
-- 恢复整行代码标记
---------------------------------------------------------------------
local function restore_code_line_from_snapshot(snapshot)
	if not snapshot or not snapshot.code then
		return
	end

	local path = snapshot.code.path
	local line = snapshot.code.line
	local tag = snapshot.code.tag or "TODO"
	local id = snapshot.id

	local prefix = comment.get_prefix_by_path(path)
	local code_mark = id_utils.format_code_mark(tag, id)
	local code_line = string.format("%s %s", prefix, code_mark)

	local lines = read_file_lines(path)
	line = math.max(1, math.min(line, #lines + 1))
	table.insert(lines, line, code_line)
	write_file_lines(path, lines)

	link.shift_lines(path, line, 1, { skip_archived = false })
end

---------------------------------------------------------------------
-- 收集整棵子树
---------------------------------------------------------------------
local function collect_tree_nodes(root, result)
	result = result or {}
	table.insert(result, root)
	for _, child in ipairs(root.children or {}) do
		collect_tree_nodes(child, result)
	end
	return result
end

---------------------------------------------------------------------
-- 获取任务状态
---------------------------------------------------------------------
local function get_authoritative_status(task)
	if not task or not task.id then
		return task and task.status
	end
	local todo_link = link.get_todo(task.id, { verify_line = false })
	return todo_link and todo_link.status or task.status
end

---------------------------------------------------------------------
-- 任务组是否全部完成
---------------------------------------------------------------------
local function is_tree_completed(root)
	local function check(node)
		if not types.is_completed_status(get_authoritative_status(node)) then
			return false
		end
		for _, c in ipairs(node.children or {}) do
			if not check(c) then
				return false
			end
		end
		return true
	end
	return check(root)
end

---------------------------------------------------------------------
-- 查找/创建归档区域（固定行为：自动创建 + 放底部）
---------------------------------------------------------------------
local function find_or_create_archive_section(bufnr, lines)
	local title = utils.build_archive_title()

	-- 查找已有归档区域
	for i, line in ipairs(lines) do
		if utils.is_archive_section_line(line) then
			local insert_point = i + 1
			while insert_point <= #lines and lines[insert_point]:match("^%s*$") do
				insert_point = insert_point + 1
			end
			return insert_point, lines
		end
	end

	-- 永远自动创建归档区域
	table.insert(lines, "")
	table.insert(lines, title)
	table.insert(lines, "")

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return #lines + 1, lines
end

---------------------------------------------------------------------
-- 构建任务层级
---------------------------------------------------------------------
local function build_task_hierarchy(tasks)
	local node_map = {}
	local roots = {}

	for _, task in ipairs(tasks) do
		node_map[task.id] = {
			task = task,
			children = {},
			level = task.level or 0,
			line_num = task.line_num,
		}
	end

	for _, node in pairs(node_map) do
		local parent = node.task.parent and node_map[node.task.parent.id] or nil
		if parent then
			table.insert(parent.children, node)
		else
			table.insert(roots, node)
		end
	end

	table.sort(roots, function(a, b)
		return a.line_num < b.line_num
	end)

	for _, node in pairs(node_map) do
		table.sort(node.children, function(a, b)
			return a.line_num < b.line_num
		end)
	end

	return roots
end

---------------------------------------------------------------------
-- 收集要移动的行
---------------------------------------------------------------------
local function collect_lines_to_move(roots, lines)
	local result = {}

	local function collect(node)
		local line = lines[node.task.line_num]
		if not line then
			return
		end

		local archived_line = line
		archived_line = archived_line:gsub("%[x%]", "[>]")
		archived_line = archived_line:gsub("%[%s%]", "[>]")

		table.insert(result, {
			line = archived_line,
			original_line = node.task.line_num,
			id = node.task.id,
			level = node.level,
			parent_id = node.task.parent and node.task.parent.id or nil,
			line_num = node.task.line_num,
		})

		for _, child in ipairs(node.children) do
			collect(child)
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
-- 移动行到归档区域
---------------------------------------------------------------------
local function move_tasks_to_archive(bufnr, tasks_to_move, archive_start, lines)
	table.sort(tasks_to_move, function(a, b)
		return a.original_line > b.original_line
	end)

	for _, item in ipairs(tasks_to_move) do
		if lines[item.original_line] then
			table.remove(lines, item.original_line)
		end
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
		local pos = insert_pos + i - 1
		table.insert(lines, pos, item.line)
		item.new_line_num = pos
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return tasks_to_move
end

---------------------------------------------------------------------
-- 更新链接
---------------------------------------------------------------------
local function update_task_lines_after_archive(tasks_to_move)
	for _, item in ipairs(tasks_to_move) do
		if item.id then
			local todo_link = link.get_todo(item.id, { verify_line = false })
			if todo_link then
				todo_link.line = item.new_line_num
				todo_link.updated_at = os.time()
				todo_link.archived_at = todo_link.archived_at or os.time()
				link.update_todo(item.id, todo_link)
			end
		end
	end
end

---------------------------------------------------------------------
-- 归档任务组
---------------------------------------------------------------------
function M.archive_task_group(root_task, bufnr, opts)
	opts = opts or {}

	if not root_task or not bufnr or bufnr == 0 then
		return false, "参数错误", nil
	end

	if not opts.force and not is_tree_completed(root_task) then
		return false, "任务组中存在未完成的任务", nil
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path or path == "" then
		return false, "无法获取文件路径", nil
	end

	local lines = scheduler.get_file_lines(path, true)
	if not lines or #lines == 0 then
		return false, "文件内容为空", nil
	end

	local tasks = collect_tree_nodes(root_task)
	if #tasks == 0 then
		return false, "没有可归档的任务", nil
	end

	local all_ids = {}
	for _, t in ipairs(tasks) do
		if t.id then
			table.insert(all_ids, t.id)
		end
	end

	for _, id in ipairs(all_ids) do
		local code_link = link.get_code(id, { verify_line = false })
		if code_link and code_link.path and code_link.line then
			local code_lines = read_file_lines(code_link.path)
			local line = code_lines[code_link.line]
			if line then
				local has_multiple, ids = line_has_multiple_ids(line)
				if has_multiple then
					return false,
						string.format(
							"代码行包含多个 ID（%s），无法归档。请拆分成多行。",
							table.concat(ids, ", ")
						),
						nil
				end
			end
		end
	end

	for _, id in ipairs(all_ids) do
		delete_entire_code_line(id)
	end

	for _, id in ipairs(all_ids) do
		link.save_archive_snapshot(id)
	end

	local roots = build_task_hierarchy(tasks)
	local tasks_to_move = collect_lines_to_move(roots, lines)
	if #tasks_to_move == 0 then
		return false, "没有可归档的任务行", nil
	end

	local archive_pos, updated_lines = find_or_create_archive_section(bufnr, lines)
	if not archive_pos then
		return false, "无法创建归档区域", nil
	end

	tasks_to_move = move_tasks_to_archive(bufnr, tasks_to_move, archive_pos, updated_lines)

	for _, id in ipairs(all_ids) do
		link.mark_archived(id, "archive_group")
	end

	update_task_lines_after_archive(tasks_to_move)

	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	events.on_state_changed({
		source = "archive_group",
		bufnr = bufnr,
		file = path,
		files = { path },
		ids = all_ids,
		timestamp = os.time() * 1000,
	})

	scheduler.invalidate_cache(path)

	return true,
		string.format("归档任务组: %d 个任务", #tasks),
		{
			root_id = root_task.id,
			total_tasks = #tasks,
			archived_ids = all_ids,
		}
end

---------------------------------------------------------------------
-- 撤销归档任务组
---------------------------------------------------------------------
function M.unarchive_task_group(root_id, bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path or path == "" then
		return false, "无法获取文件路径"
	end

	local group = link.get_task_group(root_id, { include_archived = true })
	if not group or #group == 0 then
		return false, "找不到任务组"
	end

	local lines = scheduler.get_file_lines(path, true)
	local moves = {}

	for _, todo_link in ipairs(group) do
		local id = todo_link.id
		local snapshot = link.get_archive_snapshot(id)
		if snapshot and snapshot.todo and snapshot.todo.path == path then
			local current_line = nil
			for i, line in ipairs(lines) do
				if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id then
					current_line = i
					break
				end
			end

			local target_line = snapshot.todo.line_num or todo_link.line or 1
			target_line = math.max(1, math.min(target_line, #lines + 1))

			local level = snapshot.todo.level or 0
			local indent = snapshot.todo.indent or string.rep("  ", level)
			local status = snapshot.todo.status or types.STATUS.NORMAL
			local checkbox = (status == types.STATUS.COMPLETED) and "[x]" or "[ ]"
			local tag = snapshot.todo.tag or "TODO"
			local content = snapshot.todo.content or ""

			local text = string.format(
				"%s- %s %s%s %s",
				indent,
				checkbox,
				tag ~= "" and (tag .. ": ") or "",
				content,
				id_utils.format_todo_anchor(id)
			)

			table.insert(moves, {
				id = id,
				current_line = current_line,
				target_line = target_line,
				text = text,
				snapshot = snapshot,
			})
		end
	end

	table.sort(moves, function(a, b)
		return (a.current_line or 0) > (b.current_line or 0)
	end)
	for _, m in ipairs(moves) do
		if m.current_line and lines[m.current_line] then
			table.remove(lines, m.current_line)
		end
	end

	table.sort(moves, function(a, b)
		return a.target_line < b.target_line
	end)
	for i, m in ipairs(moves) do
		local pos = math.min(m.target_line + i - 1, #lines + 1)
		table.insert(lines, pos, m.text)
		m.new_line = pos
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	local restored_ids = {}
	for _, m in ipairs(moves) do
		link.unarchive_link(m.id, { delete_snapshot = false })
		local todo_link = link.get_todo(m.id, { verify_line = false })
		if todo_link then
			todo_link.line = m.new_line
			todo_link.updated_at = os.time()
			link.update_todo(m.id, todo_link)
		end
		table.insert(restored_ids, m.id)
	end

	for _, m in ipairs(moves) do
		restore_code_line_from_snapshot(m.snapshot)
	end

	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	events.on_state_changed({
		source = "unarchive_group",
		file = path,
		files = { path },
		bufnr = bufnr,
		ids = restored_ids,
		timestamp = os.time() * 1000,
	})

	scheduler.invalidate_cache(path)

	return true, "恢复归档任务组: " .. tostring(#restored_ids) .. " 个任务"
end

return M
