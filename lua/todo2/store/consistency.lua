-- lua/todo2/store/consistency.lua
--- @module todo2.store.consistency
--- 简化一致性检查

local M = {}

local store = require("todo2.store.nvim_store")

--- 检查链接对一致性
function M.check_link_pair_consistency(id)
	local todo_key = "todo.links.todo." .. id
	local code_key = "todo.links.code." .. id

	local todo_link = store.get_key(todo_key)
	local code_link = store.get_key(code_key)

	local result = {
		id = id,
		has_todo = todo_link ~= nil,
		has_code = code_link ~= nil,
		status_consistent = true,
		needs_repair = false,
	}

	if not todo_link and not code_link then
		result.message = "链接不存在"
		return result
	end

	-- 状态一致性检查
	if todo_link and code_link and todo_link.status ~= code_link.status then
		result.status_consistent = false
		result.needs_repair = true
		result.message = string.format("状态不一致: TODO=%s, 代码=%s", todo_link.status, code_link.status)
	else
		result.message = "状态一致"
	end

	return result
end

--- 修复链接对不一致
function M.repair_link_pair(id, strategy)
	strategy = strategy or "latest"

	local todo_key = "todo.links.todo." .. id
	local code_key = "todo.links.code." .. id

	local todo_link = store.get_key(todo_key)
	local code_link = store.get_key(code_key)

	if not todo_link or not code_link then
		return {
			repaired = false,
			message = "缺少链接，无法修复",
		}
	end

	-- 确定主链接（根据策略）
	local primary, secondary
	if strategy == "todo_first" then
		primary, secondary = todo_link, code_link
	else
		-- 默认使用更新时间最新的
		if todo_link.updated_at >= code_link.updated_at then
			primary, secondary = todo_link, code_link
		else
			primary, secondary = code_link, todo_link
		end
	end

	-- 同步状态
	if secondary.status ~= primary.status then
		secondary.status = primary.status
		secondary.previous_status = primary.previous_status
		secondary.completed_at = primary.completed_at
		secondary.updated_at = os.time()
		secondary.sync_version = (secondary.sync_version or 0) + 1

		-- 保存更新
		if secondary.type == "todo_to_code" then
			store.set_key(todo_key, secondary)
		else
			store.set_key(code_key, secondary)
		end

		return {
			repaired = true,
			message = "已修复状态不一致",
		}
	end

	return {
		repaired = false,
		message = "无需修复",
	}
end

return M
