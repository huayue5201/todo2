-- lua/todo2/core/archive.lua
-- 归档业务层：处理所有归档相关的业务逻辑
---@module "todo2.core.archive"

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local events = require("todo2.core.events")
local id_utils = require("todo2.utils.id")
local file = require("todo2.utils.file")
local archive_store = require("todo2.store.task.archive")
local editor = require("todo2.core.archive_editor")
local status_domain = require("todo2.core.status")

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------

---清理任务在存储中的代码位置（归档时调用）
---@param id string 任务ID
local function delete_code_line(id)
	-- 清理索引与代码位置
	local task = core.get_task(id)
	if not task or not task.locations.code then
		return
	end

	-- 清理索引
	local index = require("todo2.store.index")
	if task.locations.code.path then
		pcall(index._internal.remove_code_id, task.locations.code.path, id)
	end

	-- 清除代码位置
	task.locations.code = nil
	task.timestamps.updated = os.time()
	core.save_task(id, task)
end

---恢复任务在存储中的代码位置（撤销归档时调用）
---@param snapshot table 快照对象
local function restore_code_line(snapshot)
	if not snapshot or not snapshot.locations or not snapshot.locations.code then
		return
	end

	local path = snapshot.locations.code.path
	local line = snapshot.locations.code.line
	local id = snapshot.id

	if not path or not line then
		return
	end

	-- 恢复代码位置到存储
	local task = core.get_task(id)
	if task then
		task.locations.code = {
			path = path,
			line = line,
			context = snapshot.locations.code.context,
		}
		task.timestamps.updated = os.time()
		core.save_task(id, task)

		-- 恢复索引
		local index = require("todo2.store.index")
		index._internal.add_code_id(path, id)
	end
end

---收集任务树所有节点ID（统一由 relation 提供）
---@param root_id string 根任务ID
---@return string[]
local collect_tree_node_ids = relation.get_subtree_ids

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
				archived_line = archived_line:gsub("%[[xX]%]", "[>]")
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

	local lines = editor.get_buffer_lines(bufnr)
	if not lines or #lines == 0 then
		return false, "文件内容为空", nil
	end

	local all_ids = collect_tree_node_ids(root_id)
	if #all_ids == 0 then
		return false, "没有可归档的任务", nil
	end

	-- 检查代码行是否包含多个 ID（代码文件无标记行，跳过此检查或改为检查代码位置）
	-- 由于不再有标记行，此检查可以简化或移除
	for _, id in ipairs(all_ids) do
		local task = core.get_task(id)
		if task and task.locations.code then
			-- 只检查是否有多个任务共享同一代码行
			local index = require("todo2.store.index")
			local tasks_at_line = index.find_code_links_by_file(task.locations.code.path)
			local count = 0
			for _, t in ipairs(tasks_at_line) do
				if t.locations.code and t.locations.code.line == task.locations.code.line then
					count = count + 1
				end
			end
			if count > 1 then
				return false,
					string.format("代码行 %d 包含多个任务，无法归档", task.locations.code.line),
					nil
			end
		end
	end

	-- 1. 保存快照（必须在清理代码位置之前，否则 code 位置会丢失，恢复时无法还原）
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

	-- 2. 清理代码位置
	for _, id in ipairs(all_ids) do
		delete_code_line(id)
	end

	-- 3. 收集并移动TODO行
	local tasks_to_move = collect_lines_to_move(root_id, lines)
	if #tasks_to_move == 0 then
		return false, "没有可归档的任务行", nil
	end

	local archive_pos, updated_lines = editor.find_or_create_archive_section(bufnr, lines)
	if not archive_pos then
		return false, "无法创建归档区域", nil
	end

	tasks_to_move = editor.move_tasks_to_archive(bufnr, tasks_to_move, archive_pos, updated_lines)

	-- 4. 更新任务状态为归档
	local now = os.time()
	for _, id in ipairs(all_ids) do
		local task = core.get_task(id)
		if task then
			status_domain.enter_terminal(task, types.STATUS.ARCHIVED, now)
			core.save_task(id, task)
		end
	end

	-- 5. 更新行号
	update_task_lines(tasks_to_move)

	-- 6. 触发自动保存
	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	-- 7. 触发事件
	events.emit("archive_group", {
		bufnr = bufnr,
		file = path,
		files = { path },
		changed_ids = all_ids,
	})

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

	local lines = editor.get_buffer_lines(bufnr)
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

			local text
			if snapshot.original_line and snapshot.original_line.raw then
				text = snapshot.original_line.raw
			else
				local ancestors = relation.get_ancestors(id)
				local level = #ancestors
				local indent = string.rep("  ", level)
				local checkbox = (snapshot.core.status == types.STATUS.COMPLETED) and "[x]" or "[ ]"
				local content = snapshot.core.content or ""

				text = string.format("%s- %s %s %s", indent, checkbox, id_utils.format_mark(id), content)
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

	local occupied_lines = {}
	for i, _ in ipairs(lines) do
		occupied_lines[i] = true
	end

	for _, m in ipairs(moves) do
		local insert_pos = m.target_line

		while occupied_lines[insert_pos] do
			insert_pos = insert_pos + 1
		end

		table.insert(lines, insert_pos, m.text)
		m.new_line = insert_pos
		occupied_lines[insert_pos] = true
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- 4. 恢复任务状态和代码位置
	local restored_ids = {}
	for _, m in ipairs(moves) do
		local task = core.get_task(m.id)
		if task then
			task.core.status = m.snapshot.core.status or types.STATUS.NORMAL
			task.core.previous_status = nil
			task.timestamps.completed = m.snapshot.timestamps.completed
			task.timestamps.archived = nil
			task.timestamps.updated = os.time()

			if task.locations.todo then
				task.locations.todo.line = m.new_line
			end

			core.save_task(m.id, task)
			table.insert(restored_ids, m.id)
		end

		restore_code_line(m.snapshot)
		archive_store.delete_task_snapshot(m.id)
	end

	-- 5. 触发自动保存
	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	-- 6. 触发事件
	events.emit("unarchive_group", {
		file = path,
		files = { path },
		bufnr = bufnr,
		changed_ids = restored_ids,
	})

	return true, "恢复归档任务组: " .. tostring(#restored_ids) .. " 个任务"
end

return M
