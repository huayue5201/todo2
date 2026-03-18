-- lua/todo2/store/link/relation.lua
-- 全新模块：管理父子任务关系

local M = {}
local core = require("todo2.store.link.core")
local store = require("todo2.store.nvim_store")

-- 关系索引命名空间
local NS = {
	PARENT_TO_CHILDREN = "todo.relation.parent_to_children.",
	CHILD_TO_PARENT = "todo.relation.child_to_parent.",
}

---------------------------------------------------------------------
-- 核心关系操作
---------------------------------------------------------------------

--- 设置父子关系
---@param parent_id string
---@param child_id string
---@return boolean
function M.set_parent_child(parent_id, child_id)
	if parent_id == child_id then
		return false
	end

	local parent = core.get_task(parent_id)
	local child = core.get_task(child_id)
	if not parent or not child then
		return false
	end

	-- 确保relations存在
	if not parent.relations then
		parent.relations = { child_ids = {} }
	end
	if not parent.relations.child_ids then
		parent.relations.child_ids = {}
	end
	if not child.relations then
		child.relations = {}
	end

	-- 移除旧的父子关系
	if child.relations.parent_id then
		local old_parent = core.get_task(child.relations.parent_id)
		if old_parent and old_parent.relations and old_parent.relations.child_ids then
			for i, cid in ipairs(old_parent.relations.child_ids) do
				if cid == child_id then
					table.remove(old_parent.relations.child_ids, i)
					core.save_task(old_parent.id, old_parent)
					break
				end
			end
		end
		store.delete_key(NS.CHILD_TO_PARENT .. child_id)
	end

	-- 建立新关系
	child.relations.parent_id = parent_id
	child.relations.level = (parent.relations.level or 0) + 1
	table.insert(parent.relations.child_ids, child_id)

	-- 保存
	core.save_task(parent_id, parent)
	core.save_task(child_id, child)

	-- 更新索引
	store.set_key(NS.PARENT_TO_CHILDREN .. parent_id, parent.relations.child_ids)
	store.set_key(NS.CHILD_TO_PARENT .. child_id, parent_id)

	return true
end

--- 移除子任务
---@param parent_id string
---@param child_id string
function M.remove_child(parent_id, child_id)
	local parent = core.get_task(parent_id)
	local child = core.get_task(child_id)
	if not parent or not child then
		return
	end

	if parent.relations and parent.relations.child_ids then
		for i, cid in ipairs(parent.relations.child_ids) do
			if cid == child_id then
				table.remove(parent.relations.child_ids, i)
				break
			end
		end
		core.save_task(parent_id, parent)
		store.set_key(NS.PARENT_TO_CHILDREN .. parent_id, parent.relations.child_ids)
	end

	if child.relations then
		child.relations.parent_id = nil
		child.relations.level = 0
		core.save_task(child_id, child)
	end

	store.delete_key(NS.CHILD_TO_PARENT .. child_id)
end

--- 获取父任务ID
---@param child_id string
---@return string?
function M.get_parent_id(child_id)
	return store.get_key(NS.CHILD_TO_PARENT .. child_id)
end

--- 获取子任务列表
---@param parent_id string
---@return string[]
function M.get_child_ids(parent_id)
	return store.get_key(NS.PARENT_TO_CHILDREN .. parent_id) or {}
end

--- 获取所有后代（递归）
---@param root_id string
---@return string[]
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

--- 获取祖先路径
---@param task_id string
---@return string[]
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

--- 获取任务树
---@param root_id string
---@return table?
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
		return {
			id = task.id,
			content = task.core.content,
			status = task.core.status,
			level = task.relations and task.relations.level or 0,
			children = vim.tbl_map(build, M.get_child_ids(id)),
		}
	end

	return build(root_id)
end

--- 从ID前缀重建关系（用于迁移）
---@param task_id string
function M.rebuild_from_id(task_id)
	local task = core.get_task(task_id)
	if not task then
		return
	end

	local parts = vim.split(task_id, ".", true)
	if #parts > 1 then
		table.remove(parts)
		local possible_parent = table.concat(parts, ".")
		if core.get_task(possible_parent) then
			M.set_parent_child(possible_parent, task_id)
		end
	end
end

--- 批量重建所有关系
function M.rebuild_all()
	local all_tasks = core.get_all_tasks()
	for id, _ in pairs(all_tasks) do
		M.rebuild_from_id(id)
	end
end

return M
