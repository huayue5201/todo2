-- lua/todo2/store/task/relation.lua
-- 父子任务关系：关系数据只存于索引命名空间，任务对象不再冗余存关系

local M = {}

local core = require("todo2.store.task.core")
local store = require("todo2.store.nvim_store")

---------------------------------------------------------------------
-- 关系索引命名空间
---------------------------------------------------------------------
local NS = {
	PARENT_TO_CHILDREN = "todo.relation.parent_to_children.",
	CHILD_TO_PARENT = "todo.relation.child_to_parent.",
}

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

	-- 若 child 已有旧父节点，先移除旧关系
	local old_parent_id = M.get_parent_id(child_id)
	if old_parent_id then
		M.remove_child(old_parent_id, child_id)
	end

	-- 建立新关系（只写索引命名空间）
	store.set_key(NS.CHILD_TO_PARENT .. child_id, parent_id)

	local children = M.get_child_ids(parent_id)
	table.insert(children, child_id)
	store.set_key(NS.PARENT_TO_CHILDREN .. parent_id, children)

	return true
end

--- 移除子任务关系
--- @param parent_id string
--- @param child_id string
function M.remove_child(parent_id, child_id)
	local children = store.get_key(NS.PARENT_TO_CHILDREN .. parent_id)
	if children then
		for i, cid in ipairs(children) do
			if cid == child_id then
				table.remove(children, i)
				break
			end
		end
		store.set_key(NS.PARENT_TO_CHILDREN .. parent_id, children)
	end

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

--- 获取任务层级（根为 0，通过父链推导）
--- @param task_id string
--- @return integer
function M.get_level(task_id)
	local level = 0
	local current = task_id
	while true do
		local parent = M.get_parent_id(current)
		if not parent then
			break
		end
		level = level + 1
		current = parent
	end
	return level
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

--- 获取子树所有 ID（含根节点）
--- @param root_id string
--- @return string[]
function M.get_subtree_ids(root_id)
	local result = { root_id }
	vim.list_extend(result, M.get_descendants(root_id))
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

--- 获取祖先链 ID（含自身，从根到当前）
--- @param task_id string
--- @return string[]
function M.get_ancestor_ids(task_id)
	local result = M.get_ancestors(task_id)
	result[#result + 1] = task_id
	return result
end

return M
