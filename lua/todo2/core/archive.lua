-- lua/todo2/core/archive.lua
-- 归档业务层：处理所有归档相关的业务逻辑
---@module "todo2.core.archive"

local M = {}

local types = require("todo2.store.types")
local link = require("todo2.store.link")
local core = require("todo2.store.link.core")
local scheduler = require("todo2.render.scheduler")
local events = require("todo2.core.events")
local id_utils = require("todo2.utils.id")
local comment = require("todo2.utils.comment")
local utils = require("todo2.core.utils")

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------

---读取文件行
---@param path string 文件路径
---@return string[]
local function read_file_lines(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	return ok and lines or {}
end

---写入文件行
---@param path string 文件路径
---@param lines string[]
local function write_file_lines(path, lines)
	pcall(vim.fn.writefile, lines, path)
end

---判断行是否包含多个ID
---@param line string 行内容
---@return boolean, string[]
local function line_has_multiple_ids(line)
	local ids = {}
	for id in line:gmatch(id_utils.TODO_ANCHOR_PATTERN) do
		table.insert(ids, id)
	end
	return #ids > 1, ids
end

---删除代码标记行
---@param id string 任务ID
local function delete_code_line(id)
	local task = core.get_task(id)
	if not task or not task.locations.code or not task.locations.code.path or not task.locations.code.line then
		return
	end

	local path = task.locations.code.path
	local line_num = task.locations.code.line
	local lines = read_file_lines(path)

	if line_num <= #lines then
		table.remove(lines, line_num)
		write_file_lines(path, lines)
		link.shift_lines(path, line_num, -1, { skip_archived = false })
	end
end

---恢复代码标记行
---@param snapshot table 快照对象
local function restore_code_line(snapshot)
	if not snapshot or not snapshot.locations or not snapshot.locations.code then
		return
	end

	local path = snapshot.locations.code.path
	local line = snapshot.locations.code.line
	local tag = snapshot.core.tags and snapshot.core.tags[1] or "TODO"
	local id = snapshot.id

	if not path or not line then
		return
	end

	local prefix = comment.get_prefix_by_path(path)
	local code_mark = id_utils.format_code_mark(tag, id)
	local code_line = string.format("%s %s", prefix, code_mark)

	local lines = read_file_lines(path)
	line = math.max(1, math.min(line, #lines + 1))
	table.insert(lines, line, code_line)
	write_file_lines(path, lines)

	link.shift_lines(path, line, 1, { skip_archived = false })
end

---收集任务树所有节点
---@param root table 根任务
---@param result table? 结果数组
---@return table[]
local function collect_tree_nodes(root, result)
	result = result or {}
	table.insert(result, root)
	for _, child in ipairs(root.children or {}) do
		collect_tree_nodes(child, result)
	end
	return result
end

---判断任务组是否全部完成
---@param root table 根任务
---@return boolean
local function is_tree_completed(root)
	local function check(node)
		local task = core.get_task(node.id)
		if not task or not types.is_completed_status(task.core.status) then
			return false
		end
		for _, child in ipairs(node.children or {}) do
			if not check(child) then
				return false
			end
		end
		return true
	end
	return check(root)
end

---查找或创建归档区域
---@param bufnr number 缓冲区号
---@param lines string[] 文件行
---@return number, string[]
local function find_or_create_archive_section(bufnr, lines)
	local title = utils.build_archive_title()

	for i, line in ipairs(lines) do
		if utils.is_archive_section_line(line) then
			local insert_point = i + 1
			while insert_point <= #lines and lines[insert_point]:match("^%s*$") do
				insert_point = insert_point + 1
			end
			return insert_point, lines
		end
	end

	table.insert(lines, "")
	table.insert(lines, title)
	table.insert(lines, "")

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return #lines + 1, lines
end

---构建任务层级树
---@param tasks table[] 任务列表
---@return table[] 根节点列表
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

---收集要移动的行
---@param roots table[] 根节点列表
---@param lines string[] 文件行
---@return table[]
local function collect_lines_to_move(roots, lines)
	local result = {}

	local function collect(node)
		local line = lines[node.task.line_num]
		if not line then
			return
		end

		-- 转换复选框： [x] 或 [ ] 都变成 [>]
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

---移动行到归档区域
---@param bufnr number 缓冲区号
---@param tasks_to_move table[] 要移动的任务行
---@param archive_start number 归档区域起始行
---@param lines string[] 文件行
---@return table[]
local function move_tasks_to_archive(bufnr, tasks_to_move, archive_start, lines)
	-- 从原位置删除（从后往前删，避免索引变化）
	table.sort(tasks_to_move, function(a, b)
		return a.original_line > b.original_line
	end)

	for _, item in ipairs(tasks_to_move) do
		if lines[item.original_line] then
			table.remove(lines, item.original_line)
		end
	end

	-- 重新按原顺序插入归档区域
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

---更新任务行号
---@param tasks_to_move table[] 移动后的任务行
local function update_task_lines(tasks_to_move)
	for _, item in ipairs(tasks_to_move) do
		if item.id then
			local task = core.get_task(item.id)
			if task and task.locations.todo then
				task.locations.todo.line = item.new_line_num
				task.timestamps.updated = os.time()
				core.save_task(item.id, task)
			end
		end
	end
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

---归档任务组
---@param root_task table 根任务对象（来自 parser）
---@param bufnr number 缓冲区号
---@param opts? { force?: boolean } 选项，force=true 强制归档（忽略完成状态）
---@return boolean, string, table?
function M.archive_task_group(root_task, bufnr, opts)
	opts = opts or {}

	if not root_task or not bufnr or bufnr == 0 then
		return false, "参数错误", nil
	end

	-- 检查完成状态（除非强制）
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

	-- 检查代码行是否包含多个 ID
	for _, id in ipairs(all_ids) do
		local task = core.get_task(id)
		if task and task.locations.code and task.locations.code.path and task.locations.code.line then
			local code_lines = read_file_lines(task.locations.code.path)
			local line = code_lines[task.locations.code.line]
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

	-- 1. 删除代码标记
	for _, id in ipairs(all_ids) do
		delete_code_line(id)
	end

	-- 2. 保存快照（传入原始行）
	for _, id in ipairs(all_ids) do
		local task = core.get_task(id)
		if task then
			local original_line = lines[task.locations.todo.line]
			link.save_task_snapshot(id, task, original_line)
		end
	end

	-- 3. 构建层级并移动TODO行
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

	-- 4. 更新任务状态为归档
	local now = os.time()
	for _, id in ipairs(all_ids) do
		local task = core.get_task(id)
		if task then
			task.core.previous_status = task.core.status
			task.core.status = types.STATUS.ARCHIVED
			task.timestamps.archived = now
			task.timestamps.archived_reason = "archive_group"
			task.timestamps.updated = now
			core.save_task(id, task)
		end
	end

	-- 5. 更新行号
	update_task_lines(tasks_to_move)

	-- 6. 触发自动保存
	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	-- 7. 触发事件
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

---撤销归档任务组
---@param root_id string 根任务ID
---@param bufnr number 缓冲区号
---@return boolean, string
function M.unarchive_task_group(root_id, bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path or path == "" then
		return false, "无法获取文件路径"
	end

	local query = require("todo2.store.link.query")
	local group = query.get_task_group(root_id, { include_archived = true })
	if not group or #group == 0 then
		return false, "找不到任务组"
	end

	local lines = scheduler.get_file_lines(path, true)
	local moves = {}

	-- 1. 收集要恢复的任务
	for _, todo_link in ipairs(group) do
		local id = todo_link.id
		local snapshot = link.get_task_snapshot(id)
		if snapshot and snapshot.locations and snapshot.locations.todo and snapshot.locations.todo.path == path then
			local current_line = nil
			for i, line in ipairs(lines) do
				if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id then
					current_line = i
					break
				end
			end

			local target_line = snapshot.locations.todo.line or todo_link.line or 1
			target_line = math.max(1, math.min(target_line, #lines + 1))

			-- 使用保存的原始行信息恢复
			local text
			if snapshot.original_line then
				-- 优先使用保存的原始行
				text = snapshot.original_line.raw
			else
				-- 没有原始行，从其他字段重建
				local level = snapshot.relations and snapshot.relations.level or 0
				local indent = string.rep("  ", level)
				local checkbox = (snapshot.core.status == types.STATUS.COMPLETED) and "[x]" or "[ ]"
				local tag = snapshot.core.tags and snapshot.core.tags[1] or "TODO"
				local content = snapshot.core.content or ""

				text = string.format(
					"%s- %s %s%s %s",
					indent,
					checkbox,
					tag ~= "" and (tag .. ": ") or "",
					content,
					id_utils.format_todo_anchor(id)
				)
			end

			table.insert(moves, {
				id = id,
				current_line = current_line,
				target_line = target_line,
				text = text,
				snapshot = snapshot,
			})
		end
	end

	if #moves == 0 then
		return false, "没有可恢复的任务"
	end

	-- 2. 从归档区域删除（从后往前）
	table.sort(moves, function(a, b)
		return (a.current_line or 0) > (b.current_line or 0)
	end)
	for _, m in ipairs(moves) do
		if m.current_line and lines[m.current_line] then
			table.remove(lines, m.current_line)
		end
	end

	-- 3. 插回主区域
	table.sort(moves, function(a, b)
		return a.target_line < b.target_line
	end)
	for i, m in ipairs(moves) do
		local pos = math.min(m.target_line + i - 1, #lines + 1)
		table.insert(lines, pos, m.text)
		m.new_line = pos
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- 4. 恢复任务状态和代码标记
	local restored_ids = {}
	for _, m in ipairs(moves) do
		local task = core.get_task(m.id)
		if task then
			-- 恢复状态
			task.core.status = m.snapshot.core.status or types.STATUS.NORMAL
			task.core.previous_status = nil
			task.timestamps.completed = m.snapshot.timestamps.completed
			task.timestamps.archived = nil
			task.timestamps.archived_reason = nil
			task.timestamps.updated = os.time()

			-- 更新行号
			if task.locations.todo then
				task.locations.todo.line = m.new_line
			end

			core.save_task(m.id, task)
			table.insert(restored_ids, m.id)
		end

		-- 恢复代码标记
		restore_code_line(m.snapshot)

		-- 删除快照（除非配置保留）
		link.delete_task_snapshot(m.id)
	end

	-- 5. 触发自动保存
	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	-- 6. 触发事件
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
