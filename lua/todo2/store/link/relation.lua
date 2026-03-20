-- lua/todo2/store/link/relation.lua
-- 纯新结构版：管理父子任务关系（无旧结构、无 ID 前缀法）

local M = {}

local core = require("todo2.store.link.core")
local store = require("todo2.store.nvim_store")

---------------------------------------------------------------------
-- 关系索引命名空间
---------------------------------------------------------------------

--- @class RelationNamespace
--- @field PARENT_TO_CHILDREN string
--- @field CHILD_TO_PARENT string
local NS = {
	PARENT_TO_CHILDREN = "todo.relation.parent_to_children.",
	CHILD_TO_PARENT = "todo.relation.child_to_parent.",
}

---------------------------------------------------------------------
-- 类型定义（严格 LuaDoc）
---------------------------------------------------------------------

--- @class TaskRelations
--- @field parent_id string|nil
--- @field child_ids string[]
--- @field level integer

--- @class TaskObject
--- @field id string
--- @field core table
--- @field relations TaskRelations|nil
--- @field timestamps table
--- @field verified boolean|nil
--- @field locations table

---------------------------------------------------------------------
-- 内部工具
---------------------------------------------------------------------

--- 确保 task.relations 结构完整
--- @param task TaskObject
local function ensure_relations(task)
	task.relations = task.relations or {}
	task.relations.child_ids = task.relations.child_ids or {}
	task.relations.level = task.relations.level or 0
end

---------------------------------------------------------------------
-- 核心关系操作
---------------------------------------------------------------------

--- 设置父子关系
--- @param parent_id string
--- @param child_id string
--- @return boolean
function M.set_parent_child(parent_id, child_id)
	if parent_id == child_id then
		return false
	end

	local parent = core.get_task(parent_id)
	local child = core.get_task(child_id)
	if not parent or not child then
		return false
	end

	ensure_relations(parent)
	ensure_relations(child)

	-- 如果 child 已经有旧父节点，先移除
	if child.relations.parent_id then
		local old_parent_id = child.relations.parent_id
		local old_parent = core.get_task(old_parent_id)

		if old_parent and old_parent.relations and old_parent.relations.child_ids then
			for i, cid in ipairs(old_parent.relations.child_ids) do
				if cid == child_id then
					table.remove(old_parent.relations.child_ids, i)
					core.save_task(old_parent_id, old_parent)
					break
				end
			end
		end

		store.delete_key(NS.CHILD_TO_PARENT .. child_id)
	end

	-- 建立新关系
	child.relations.parent_id = parent_id
	child.relations.level = parent.relations.level + 1
	table.insert(parent.relations.child_ids, child_id)

	-- 保存
	core.save_task(parent_id, parent)
	core.save_task(child_id, child)

	-- 更新关系索引
	store.set_key(NS.PARENT_TO_CHILDREN .. parent_id, parent.relations.child_ids)
	store.set_key(NS.CHILD_TO_PARENT .. child_id, parent_id)

	return true
end

--- 移除子任务
--- @param parent_id string
--- @param child_id string
function M.remove_child(parent_id, child_id)
	local parent = core.get_task(parent_id)
	local child = core.get_task(child_id)
	if not parent or not child then
		return
	end

	ensure_relations(parent)
	ensure_relations(child)

	-- 从父节点移除
	for i, cid in ipairs(parent.relations.child_ids) do
		if cid == child_id then
			table.remove(parent.relations.child_ids, i)
			break
		end
	end

	core.save_task(parent_id, parent)
	store.set_key(NS.PARENT_TO_CHILDREN .. parent_id, parent.relations.child_ids)

	-- 清除子节点的父关系
	child.relations.parent_id = nil
	child.relations.level = 0
	core.save_task(child_id, child)

	store.delete_key(NS.CHILD_TO_PARENT .. child_id)
end

---------------------------------------------------------------------
-- 查询 API
---------------------------------------------------------------------

--- 获取父任务ID
--- @param child_id string
--- @return string|nil
function M.get_parent_id(child_id)
	return store.get_key(NS.CHILD_TO_PARENT .. child_id)
end

--- 获取子任务ID列表
--- @param parent_id string
--- @return string[]
function M.get_child_ids(parent_id)
	return store.get_key(NS.PARENT_TO_CHILDREN .. parent_id) or {}
end

--- 获取所有后代（递归）
--- @param root_id string
--- @return string[]
function M.get_descendants(root_id)
	local result = {}

	local function collect(id)
		for _, child_id in ipairs(M.get_child_ids(id)) do
			table.insert(result, child_id)
			collect(child_id)
		end
	end

	collect(root_id)
	return result
end

--- 获取祖先路径（从根到当前）
--- @param task_id string
--- @return string[]
function M.get_ancestors(task_id)
	local ancestors = {}
	local current = task_id

	while true do
		local parent = M.get_parent_id(current)
		if not parent then
			break
		end
		table.insert(ancestors, 1, parent)
		current = parent
	end

	return ancestors
end

---------------------------------------------------------------------
-- 构建任务树
---------------------------------------------------------------------

--- 获取任务树（包含所有子节点）
--- @param root_id string
--- @return table|nil
function M.get_task_tree(root_id)
	local root = core.get_task(root_id)
	if not root then
		return nil
	end

	local function build(id)
		local task = core.get_task(id)
		if not task then
			return nil
		end

		ensure_relations(task)

		local children = {}
		for _, cid in ipairs(task.relations.child_ids) do
			local child_node = build(cid)
			if child_node then
				table.insert(children, child_node)
			end
		end

		return {
			id = task.id,
			content = task.core.content,
			status = task.core.status,
			level = task.relations.level,
			children = children,
		}
	end

	return build(root_id)
end

return M
