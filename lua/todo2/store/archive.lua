-- lua/todo2/store/archive.lua
--- @module todo2.store.archive
--- 归档查询层（**派生视图**）。
---
--- 架构契约：归档任务的唯一真相源是 TODO 文件里的 `## Archived (YYYY-MM)` 段。
--- 主 store 缓存全部任务（活跃 + 归档），归档状态 = `core.status == "archived"`。
--- 本模块只做「读取 / 派生 / 一次性重定位」，**不再有独立冷存储**，
--- 也不再有任何 store→文件的反向写入。

local M = {}

local config = require("todo2.config")
local store = require("todo2.store.nvim_store")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local types = require("todo2.store.types")
local namespace = require("todo2.store.namespace")

--- 归档索引键（保留以兼容文档/迁移；内容由任务状态派生，不再单独持久化）
M.INDEX_KEY = namespace.facts.archive_index

---------------------------------------------------------------------
-- 派生：主 store 里所有归档任务
---------------------------------------------------------------------

---收集主 store 中全部归档任务
---@return table[]
local function archived_tasks()
	local ids = store.get_namespace_keys(namespace.facts.tasks_ns) or {}
	local out = {}
	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task and task.core.status == types.STATUS.ARCHIVED then
			out[#out + 1] = task
		end
	end
	return out
end

---墓碑视图：{ [id] = { at, file, line } }。由任务状态派生（不再独立存储）。
---@return table<string, table>
function M.all_tombstones()
	local map = {}
	for _, task in ipairs(archived_tasks()) do
		local loc = task.locations and task.locations.todo
		map[task.id] = {
			at = task.timestamps and task.timestamps.archived,
			file = loc and loc.path or nil,
			line = loc and loc.line or nil,
		}
	end
	return map
end

---该 id 是否已归档
---@param id string
---@return boolean
function M.is_archived(id)
	local task = core.get_task(id)
	return task ~= nil and task.core.status == types.STATUS.ARCHIVED
end

---------------------------------------------------------------------
-- 冷库生命周期：派生化后不存在独立库，保留空实现以兼容调用方
---------------------------------------------------------------------

function M.is_open()
	return false
end

function M.open()
	return false
end

function M.close()
	M._anchors_refreshed = nil
	return false
end

---归档任务数量
---@return number
function M.count()
	return #archived_tasks()
end

---------------------------------------------------------------------
-- 锚点重定位 / 清理 / 冲突
---------------------------------------------------------------------

---对归档任务的冻结代码锚点做一次重解析（落 ok/stale/lost）。每会话一次。
---@return number relocated, number lost
function M.refresh_anchors()
	if M._anchors_refreshed then
		return 0, 0
	end
	local relocated, lost = 0, 0
	for _, task in ipairs(archived_tasks()) do
		local loc = task.locations and task.locations.code
		-- 只有带 context 的锚点才能重解析；裸锚点跳过，避免误标 lost
		if loc and loc.path and loc.context then
			if core.relocate_code_location(task.id, loc.path) then
				relocated = relocated + 1
			else
				lost = lost + 1
			end
		end
	end
	M._anchors_refreshed = true
	return relocated, lost
end

---保留策略清理。派生模型下归档生命周期由文件决定，这里不删除任何数据。
---@return number pruned_tombstones, number pruned_tasks
function M.prune()
	return 0, 0
end

---冲突检测。冷库已取消，主库/冷库冲突不复存在。
---@return table[]
function M.find_conflicts()
	return {}
end

---------------------------------------------------------------------
-- 查询：构建归档任务森林（供 viewer / qf / drawer 复用）
---------------------------------------------------------------------

---由归档任务列表构建森林（结构来自 store 关系，关系由文件同步建立）
---@param task_list table[]
---@return table[] roots
local function build_forest(task_list)
	local map = {}
	for _, t in ipairs(task_list) do
		map[t.id] = { id = t.id, task = t, children = {} }
	end

	local roots = {}
	for _, t in ipairs(task_list) do
		local parent = relation.get_parent_id(t.id)
		if parent and map[parent] then
			table.insert(map[parent].children, map[t.id])
		else
			table.insert(roots, map[t.id])
		end
	end

	local function sort_nodes(nodes)
		table.sort(nodes, function(a, b)
			local ta = (a.task.timestamps and a.task.timestamps.archived) or 0
			local tb = (b.task.timestamps and b.task.timestamps.archived) or 0
			if ta ~= tb then
				return ta > tb
			end
			return a.id < b.id
		end)
		for _, n in ipairs(nodes) do
			sort_nodes(n.children)
		end
	end
	sort_nodes(roots)

	return roots
end

---全部归档任务的森林
---@return table[] roots, table[] task_list
function M.forest()
	local tasks = archived_tasks()
	M.refresh_anchors()
	return build_forest(tasks), tasks
end

---------------------------------------------------------------------
-- 自动归档：把「整棵子树均已完成且早于阈值」的根任务组移入归档段
---------------------------------------------------------------------

---@return number 归档的根任务组数
function M.auto_archive()
	local days = config.get("archive.auto_after_days") or 0
	if days <= 0 then
		return 0
	end
	local cutoff = os.time() - days * 86400

	local roots = {}
	local ids = store.get_namespace_keys(namespace.facts.tasks_ns) or {}
	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task and not relation.get_parent_id(id) and task.core.status == types.STATUS.COMPLETED then
			local completed = task.timestamps and task.timestamps.completed
			if completed and completed < cutoff then
				local subtree = relation.get_subtree_ids(id)
				local all_done = true
				for _, sid in ipairs(subtree) do
					local st = core.get_task(sid)
					if not st or not types.is_completed_status(st.core.status) then
						all_done = false
						break
					end
				end
				if all_done then
					roots[#roots + 1] = id
				end
			end
		end
	end

	local count = 0
	for _, root_id in ipairs(roots) do
		local ok = pcall(function()
			require("todo2.core.archive").archive_task_group(root_id, { force = true })
		end)
		if ok then
			count = count + 1
		end
	end
	return count
end

return M
