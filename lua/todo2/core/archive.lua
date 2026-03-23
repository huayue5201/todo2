-- lua/todo2/core/archive.lua
-- 归档业务层：处理所有归档相关的业务逻辑
---@module "todo2.core.archive"

local M = {}

local types = require("todo2.store.types")
local offset = require("todo2.store.link.offset")
local core = require("todo2.store.link.core")
local relation = require("todo2.store.link.relation")
local scheduler = require("todo2.render.scheduler")
local events = require("todo2.core.events")
local id_utils = require("todo2.utils.id")
local comment = require("todo2.utils.comment")
local utils = require("todo2.core.utils")
local file = require("todo2.utils.file")
local archive_store = require("todo2.store.link.archive")

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------

---读取文件行
---@param path string 文件路径
---@return string[]
local function read_file_lines(path)
	return file.read_lines(path)
end

---写入文件行
---@param path string 文件路径
---@param lines string[]
local function write_file_lines(path, lines)
	return file.write_lines(path, lines)
end

---判断行是否包含多个ID
---@param line string|nil 行内容
---@return boolean, string[]
local function line_has_multiple_ids(line)
	if not line then
		return false, {}
	end

	local ids = {}
	for id in line:gmatch(":ref:(" .. id_utils.ID_PATTERN .. ")") do
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
		offset.shift_lines(path, line_num, -1, { skip_archived = false })
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
	local code_mark = id_utils.format_mark(tag, id)
	local code_line = string.format("%s %s", prefix, code_mark)

	local lines = read_file_lines(path)
	line = math.max(1, math.min(line, #lines + 1))
	table.insert(lines, line, code_line)
	write_file_lines(path, lines)

	offset.shift_lines(path, line, 1, { skip_archived = false })
end

---收集任务树所有节点ID
---@param root_id string 根任务ID
---@param result table? 结果数组
---@return string[]
local function collect_tree_node_ids(root_id, result)
	result = result or {}
	table.insert(result, root_id)
	local child_ids = relation.get_child_ids(root_id)
	for _, child_id in ipairs(child_ids) do
		collect_tree_node_ids(child_id, result)
	end
	return result
end

---判断任务组是否全部完成
---@param root_id string 根任务ID
---@return boolean
local function is_tree_completed(root_id)
	local all_ids = collect_tree_node_ids(root_id)

	for _, id in ipairs(all_ids) do
		local task = core.get_task(id)
		if not task or not types.is_completed_status(task.core.status) then
			return false
		end
	end
	return true
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

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return #lines + 1, lines
end

---收集要移动的行
---@param root_id string 根任务ID
---@param lines string[] 文件行
---@return table[]
local function collect_lines_to_move(root_id, lines)
	local result = {}
	local all_ids = collect_tree_node_ids(root_id)

	-- 按行号排序
	table.sort(all_ids, function(a, b)
		local a_loc = core.get_todo_location(a)
		local b_loc = core.get_todo_location(b)
		return (a_loc and a_loc.line or 0) < (b_loc and b_loc.line or 0)
	end)

	for _, id in ipairs(all_ids) do
		local loc = core.get_todo_location(id)
		if loc and loc.line then
			local line = lines[loc.line]
			if line then
				local ancestors = relation.get_ancestors(id)
				local level = #ancestors
				local parent_id = ancestors[#ancestors]

				-- 转换复选框： [x] 或 [ ] 都变成 [>]
				local archived_line = line
				archived_line = archived_line:gsub("%[x%]", "[>]")
				archived_line = archived_line:gsub("%[%s%]", "[>]")

				table.insert(result, {
					line = archived_line,
					original_line = loc.line,
					id = id,
					level = level,
					parent_id = parent_id,
				})
			end
		end
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
---@param root_id string 根任务ID
---@param bufnr number 缓冲区号
---@param opts? { force?: boolean } 选项，force=true 强制归档（忽略完成状态）
---@return boolean, string, table?
function M.archive_task_group(root_id, bufnr, opts)
	opts = opts or {}

	if not root_id or not bufnr or bufnr == 0 then
		return false, "参数错误", nil
	end

	-- 检查完成状态（除非强制）
	if not opts.force and not is_tree_completed(root_id) then
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

	local all_ids = collect_tree_node_ids(root_id)
	if #all_ids == 0 then
		return false, "没有可归档的任务", nil
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
			local loc = core.get_todo_location(id)
			if loc and loc.line then
				local original_line = lines[loc.line]
				archive_store.save_task_snapshot(id, task, original_line)
			end
		end
	end

	-- 3. 收集并移动TODO行
	local tasks_to_move = collect_lines_to_move(root_id, lines)
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
		string.format("归档任务组: %d 个任务", #all_ids),
		{
			root_id = root_id,
			total_tasks = #all_ids,
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

	local all_ids = collect_tree_node_ids(root_id)
	if #all_ids == 0 then
		return false, "找不到任务组"
	end

	local lines = scheduler.get_file_lines(path, true)
	local moves = {}

	-- 1. 收集要恢复的任务
	for _, id in ipairs(all_ids) do
		local snapshot = archive_store.get_task_snapshot(id)
		if snapshot and snapshot.locations and snapshot.locations.todo and snapshot.locations.todo.path == path then
			local current_line = nil
			for i, line in ipairs(lines) do
				if line and line:find(":ref:" .. id) then
					current_line = i
					break
				end
			end

			local target_line = snapshot.locations.todo.line or 1
			target_line = math.max(1, math.min(target_line, #lines + 1))

			-- 使用保存的原始行信息恢复
			local text
			if snapshot.original_line and snapshot.original_line.raw then
				text = snapshot.original_line.raw
			else
				local ancestors = relation.get_ancestors(id)
				local level = #ancestors
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
					id_utils.format_mark(tag, id)
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

	-- 3. 重新计算插入位置，避免行号冲突
	table.sort(moves, function(a, b)
		return a.target_line < b.target_line
	end)

	-- 构建已占用行号的集合
	local occupied_lines = {}
	for i, _ in ipairs(lines) do
		occupied_lines[i] = true
	end

	-- 逐个插入，遇到冲突就往后找空位
	for _, m in ipairs(moves) do
		local insert_pos = m.target_line

		-- 如果目标行已被占用，往后找第一个空位
		while occupied_lines[insert_pos] do
			insert_pos = insert_pos + 1
		end

		-- 插入到找到的位置
		table.insert(lines, insert_pos, m.text)
		m.new_line = insert_pos

		-- 更新占用标记
		occupied_lines[insert_pos] = true
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
			task.timestamps.updated = os.time()

			-- 更新行号（使用实际插入的行号）
			if task.locations.todo then
				task.locations.todo.line = m.new_line
			end

			core.save_task(m.id, task)
			table.insert(restored_ids, m.id)
		end

		-- 恢复代码标记
		restore_code_line(m.snapshot)

		-- 删除快照
		archive_store.delete_task_snapshot(m.id)
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

---处理任务移入归档区（自动触发）
---@param path string 文件路径
---@param task_ids string[] 任务ID列表
---@return boolean
function M.handle_move_to_archive(path, task_ids)
	if not path or #task_ids == 0 then
		return false
	end

	local lines = read_file_lines(path)
	local now = os.time()
	local moved_ids = {}

	for _, id in ipairs(task_ids) do
		local task = core.get_task(id)
		if task and task.locations.todo then
			local line_num = task.locations.todo.line
			local line = lines[line_num]

			if line then
				-- 保存快照
				archive_store.save_task_snapshot(id, task, line)

				-- 转换复选框
				local archived_line = line:gsub("%[x%]", "[>]"):gsub("%[%s%]", "[>]")
				lines[line_num] = archived_line

				-- 更新状态
				task.core.previous_status = task.core.status
				task.core.status = types.STATUS.ARCHIVED
				task.timestamps.archived = now
				task.timestamps.updated = now
				core.save_task(id, task)

				table.insert(moved_ids, id)
			end
		end
	end

	if #moved_ids > 0 then
		write_file_lines(path, lines)
		events.on_state_changed({
			source = "auto_archive",
			file = path,
			ids = moved_ids,
		})
	end

	return #moved_ids > 0
end

---处理任务移出归档区（自动触发）
---@param path string 文件路径
---@param task_ids string[] 任务ID列表
---@return boolean
function M.handle_move_from_archive(path, task_ids)
	if not path or #task_ids == 0 then
		return false
	end

	local lines = read_file_lines(path)
	local now = os.time()
	local restored_ids = {}

	for _, id in ipairs(task_ids) do
		local task = core.get_task(id)
		local snapshot = archive_store.get_task_snapshot(id)

		if task and snapshot and task.locations.todo then
			local line_num = task.locations.todo.line

			if snapshot.original_line and snapshot.original_line.raw then
				lines[line_num] = snapshot.original_line.raw
			end

			task.core.status = snapshot.core.status or types.STATUS.NORMAL
			task.core.previous_status = nil
			task.timestamps.archived = nil
			task.timestamps.updated = now
			core.save_task(id, task)

			archive_store.delete_task_snapshot(id)
			table.insert(restored_ids, id)
		end
	end

	if #restored_ids > 0 then
		write_file_lines(path, lines)
		events.on_state_changed({
			source = "auto_unarchive",
			file = path,
			ids = restored_ids,
		})
	end

	return #restored_ids > 0
end

---处理区域移动（统一入口）
---@param path string 文件路径
---@param old_region string 原区域
---@param new_region string 新区域
---@param task_ids string[] 任务ID列表
---@return boolean
function M.handle_region_move(path, old_region, new_region, task_ids)
	if old_region == new_region or #task_ids == 0 then
		return false
	end

	if new_region == "archive" then
		return M.handle_move_to_archive(path, task_ids)
	elseif old_region == "archive" and new_region == "main" then
		return M.handle_move_from_archive(path, task_ids)
	end

	return false
end

---批量处理区域移动
---@param path string 文件路径
---@param region_changes table<string, string[]> 按新区域分组的任务ID
---@return table<string, boolean> 处理结果
function M.handle_batch_region_move(path, region_changes)
	local results = {}

	for region, ids in pairs(region_changes) do
		if region == "archive" then
			results.archive = M.handle_move_to_archive(path, ids)
		elseif region == "main" then
			results.main = M.handle_move_from_archive(path, ids)
		end
	end

	return results
end

return M
