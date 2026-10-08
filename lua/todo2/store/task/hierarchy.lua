-- lua/todo2/store/task/hierarchy.lua
-- 同一代码行任务的层级排序：把同组任务按「祖先在前、后代缩进」排列，
-- 供代码端渲染与跳转选择复用。

local M = {}

local relation = require("todo2.store.task.relation")
local types = require("todo2.store.types")

-- 活跃状态优先级：数字越小越靠前；doing 最相关，其次 todo、blocked。
-- 不在表里的自定义活跃状态排在显式活跃状态之后、终态之前。
local ACTIVE_PRIORITY = {
	doing = 1,
	todo = 2,
	blocked = 3,
}

--- 计算任务用于排序 / 选取代表项的优先级（越小越靠前）。
---@param status string
---@return number
function M.status_priority(status)
	local p = ACTIVE_PRIORITY[status]
	if p then
		return p
	end
	if status == types.STATUS.COMPLETED then
		return 100
	end
	if status == types.STATUS.ARCHIVED then
		return 200
	end
	return 50
end

--- 展示先后：先按状态优先级，再按 id。
---@param a table
---@param b table
---@return boolean
local function cmp(a, b)
	local pa = M.status_priority(a.core.status)
	local pb = M.status_priority(b.core.status)
	if pa ~= pb then
		return pa < pb
	end
	return (a.id or "") < (b.id or "")
end

--- 把同一行上的任务整理成层级顺序。
--- 返回列表项 `{ task = <task>, depth = <同组祖先数量> }`：
--- 根（组 / 无同组祖先）在前，其后代紧随其后并带缩进深度。
---@param tasks table[]
---@return { task: table, depth: number }[]
function M.build(tasks)
	local in_group = {}
	for _, t in ipairs(tasks) do
		in_group[t.id] = t
	end

	local children = {}
	local roots = {}
	for _, t in ipairs(tasks) do
		-- get_ancestors 返回 [根 ... 父]，从近到远找最近的同组祖先
		local ancestors = relation.get_ancestors(t.id)
		local parent = nil
		for i = #ancestors, 1, -1 do
			if in_group[ancestors[i]] then
				parent = ancestors[i]
				break
			end
		end
		if parent then
			children[parent] = children[parent] or {}
			table.insert(children[parent], t)
		else
			table.insert(roots, t)
		end
	end

	table.sort(roots, cmp)
	for _, list in pairs(children) do
		table.sort(list, cmp)
	end

	local ordered = {}
	local function dfs(task, depth)
		table.insert(ordered, { task = task, depth = depth })
		for _, child in ipairs(children[task.id] or {}) do
			dfs(child, depth + 1)
		end
	end
	for _, root in ipairs(roots) do
		dfs(root, 0)
	end

	return ordered
end

return M
