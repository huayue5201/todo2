-- lua/todo2/store/archive.lua
--- @module todo2.store.archive
--- 归档数据层：把任务从主库「移动」到独立冷存储（named store "archive"），
--- 主库只保留轻量墓碑（todo.archive.index）用于反归档定位。
--- 归档 = 移动，可逆；id 全程保留。冷库不常驻，按需 open/close。

local M = {}

local store = require("todo2.store.nvim_store")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local index = require("todo2.store.index")
local types = require("todo2.store.types")
local status_domain = require("todo2.core.status")

---归档库名
M.STORE_NAME = "archive"

---主库中的归档墓碑键：{ [id] = { at, file, anchor, parent, status } }
M.INDEX_KEY = "todo.archive.index"

---------------------------------------------------------------------
-- 墓碑（主库）
---------------------------------------------------------------------

---读取全部墓碑
---@return table<string, table>
function M.all_tombstones()
	return store.get_key(M.INDEX_KEY) or {}
end

---获取某任务的墓碑
---@param id string
---@return table|nil
function M.tombstone(id)
	return M.all_tombstones()[id]
end

---该 id 是否已归档
---@param id string
---@return boolean
function M.is_archived(id)
	return M.all_tombstones()[id] ~= nil
end

---写入墓碑（合并）
---@param entries table<string, table>
local function write_tombstones(entries)
	local t = M.all_tombstones()
	for id, entry in pairs(entries) do
		t[id] = entry
	end
	store.set_key(M.INDEX_KEY, t)
end

---删除墓碑
---@param ids string[]
local function remove_tombstones(ids)
	local t = M.all_tombstones()
	local changed = false
	for _, id in ipairs(ids) do
		if t[id] ~= nil then
			t[id] = nil
			changed = true
		end
	end
	if changed then
		if vim.tbl_isempty(t) then
			store.delete_key(M.INDEX_KEY)
		else
			store.set_key(M.INDEX_KEY, t)
		end
	end
end

---------------------------------------------------------------------
-- 冷库生命周期
---------------------------------------------------------------------

---归档库是否已加载
---@return boolean
function M.is_open()
	return store.is_loaded(M.STORE_NAME)
end

---打开（加载）归档库
---@return boolean
function M.open()
	if M.is_open() then
		return false
	end
	store.get_named(M.STORE_NAME)
	return true
end

---关闭（卸载）归档库
---@return boolean
function M.close()
	if not M.is_open() then
		return false
	end
	return store.unload(M.STORE_NAME)
end

---归档库内的任务数量
---@return number
function M.count()
	return #store.with_active(M.STORE_NAME, function()
		return store.get_namespace_keys("todo.tasks") or {}
	end)
end

---------------------------------------------------------------------
-- 归档（主库 -> 冷库）
---------------------------------------------------------------------

---在主库中收集子树，并在冷库中重建（任务 + 内部关系 + 文件索引）
---@param ids string[] 子树全部 id（含根）
---@return table[] tasks 归档后的任务对象（带 id 字段）
local function spill_to_cold(ids)
	local id_set = {}
	for _, id in ipairs(ids) do
		id_set[id] = true
	end

	-- 1. 主库读取：任务快照 + 父链
	local snapshots = {}
	local parents = {}
	local now = os.time()
	store.with_active("default", function()
		for _, id in ipairs(ids) do
			local task = core.get_task(id)
			if task then
				snapshots[id] = task
				parents[id] = relation.get_parent_id(id)
			end
		end
	end)

	-- 2. 冷库写入：任务（状态 archived）+ 内部关系 + 索引
	store.with_active(M.STORE_NAME, function()
		for _, id in ipairs(ids) do
			local task = snapshots[id]
			if task then
				status_domain.enter_terminal(task, types.STATUS.ARCHIVED, now)
				core.save_task(id, task)
				if task.locations and task.locations.todo then
					index._internal.add_todo_id(task.locations.todo.path, id)
				end
				if task.locations and task.locations.code then
					index._internal.add_code_id(task.locations.code.path, id)
				end
			end
		end
		for _, id in ipairs(ids) do
			local p = parents[id]
			if p and id_set[p] then
				relation.set_parent_child(p, id)
			end
		end
	end)

	-- 3. 冷库先落盘，成功后再删主库（崩溃安全）
	store.flush(M.STORE_NAME)

	-- 4. 主库删除 + 墓碑
	local tombstones = {}
	local result = {}
	store.with_active("default", function()
		for _, id in ipairs(ids) do
			local task = snapshots[id]
			if task then
				tombstones[id] = {
					at = now,
					file = task.locations and task.locations.todo and task.locations.todo.path or nil,
					line = task.locations and task.locations.todo and task.locations.todo.line or nil,
					anchor = task.locations and task.locations.code and task.locations.code.path or nil,
					parent = parents[id],
					status = task.core.previous_status or types.STATUS.COMPLETED,
				}
				core.delete_task(id)
				table.insert(result, task)
			end
		end
		write_tombstones(tombstones)
	end)

	return result
end

---归档一个子树（或一组任务）
---@param ids string[] 要归档的任务 id；应为完整子树
---@return boolean ok, string msg, table[] tasks
function M.archive_ids(ids)
	if not ids or #ids == 0 then
		return false, "No tasks to archive", {}
	end

	-- 只归档主库中确实存在、且尚未归档的任务
	local valid = {}
	store.with_active("default", function()
		for _, id in ipairs(ids) do
			if core.get_task(id) then
				table.insert(valid, id)
			end
		end
	end)

	if #valid == 0 then
		return false, "No tasks to archive", {}
	end

	local tasks = spill_to_cold(valid)
	return true, string.format("Archived %d tasks", #tasks), tasks
end

---------------------------------------------------------------------
-- 反归档（冷库 -> 主库）
---------------------------------------------------------------------

---把归档任务恢复回主库
---@param ids string[] 要恢复的 id（应为冷库中的完整子树）
---@return boolean ok, string msg, table[] tasks
function M.unarchive_ids(ids)
	if not ids or #ids == 0 then
		return false, "No tasks to unarchive", {}
	end

	local id_set = {}
	for _, id in ipairs(ids) do
		id_set[id] = true
	end

	local snapshots = {}
	local parents = {}
	store.with_active(M.STORE_NAME, function()
		for _, id in ipairs(ids) do
			local task = core.get_task(id)
			if task then
				snapshots[id] = task
				parents[id] = relation.get_parent_id(id)
			end
		end
	end)

	if vim.tbl_isempty(snapshots) then
		return false, "No archived tasks found", {}
	end

	local result = {}
	local now = os.time()
	store.with_active("default", function()
		for _, id in ipairs(ids) do
			local task = snapshots[id]
			if task then
				local restore = task.core.previous_status or types.STATUS.COMPLETED
				status_domain.exit_terminal(task, restore, now)
				core.save_task(id, task)
				if task.locations and task.locations.todo then
					index._internal.add_todo_id(task.locations.todo.path, id)
				end
				if task.locations and task.locations.code then
					index._internal.add_code_id(task.locations.code.path, id)
				end
				table.insert(result, task)
			end
		end
		-- 恢复内部父子关系；根对外部父的关系仅在父仍存在时恢复
		for _, id in ipairs(ids) do
			local p = parents[id]
			if p then
				if id_set[p] then
					relation.set_parent_child(p, id)
				elseif core.get_task(p) then
					relation.set_parent_child(p, id)
				end
			end
		end
		remove_tombstones(ids)
	end)

	-- 冷库删除
	store.with_active(M.STORE_NAME, function()
		for _, id in ipairs(ids) do
			core.delete_task(id)
		end
	end)
	store.flush(M.STORE_NAME)

	return true, string.format("Unarchived %d tasks", #result), result
end

---------------------------------------------------------------------
-- 查询：从冷库构建任务森林（供 viewer / qf 复用）
---------------------------------------------------------------------

---节点：{ id, task, children }
---@param task_list table[]
---@param parents table<string, string|nil>
---@return table[] roots
local function build_forest(task_list, parents)
	local map = {}
	for _, t in ipairs(task_list) do
		map[t.id] = { id = t.id, task = t, children = {} }
	end

	local roots = {}
	for _, t in ipairs(task_list) do
		local node = map[t.id]
		local p = parents[t.id]
		if p and map[p] then
			table.insert(map[p].children, node)
		else
			table.insert(roots, node)
		end
	end

	-- 排序：归档时间倒序（新归档在前），无时间则按 id
	local function cmp(a, b)
		local ta = a.task.timestamps and a.task.timestamps.archived or 0
		local tb = b.task.timestamps and b.task.timestamps.archived or 0
		if ta ~= tb then
			return ta > tb
		end
		return (a.id or "") < (b.id or "")
	end

	table.sort(roots, cmp)
	for _, node in pairs(map) do
		table.sort(node.children, cmp)
	end

	return roots
end

---列出冷库中的所有任务并构建森林（会加载归档库）
---@return table[] roots, table<string, table> task_map
function M.forest()
	M.open()
	return store.with_active(M.STORE_NAME, function()
		local ids = store.get_namespace_keys("todo.tasks") or {}
		local task_list = {}
		local parents = {}
		for _, id in ipairs(ids) do
			local task = core.get_task(id)
			if task then
				task_list[#task_list + 1] = task
				parents[id] = relation.get_parent_id(id)
			end
		end
		local roots = build_forest(task_list, parents)
		return roots, task_list
	end)
end

return M
