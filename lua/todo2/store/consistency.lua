--- File: /Users/lijia/todo2/lua/todo2/store/consistency.lua ---
-- lua/todo2/store/consistency.lua
--- @module todo2.store.consistency
--- 简化一致性检查

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")

--- 检查链接对一致性
--- @param id string 链接ID
--- @return table 检查结果
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

--- 批量检查所有链接对的一致性
--- @return table 一致性报告
function M.check_all_pairs()
	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local report = {
		total_checked = 0,
		consistent_pairs = 0,
		inconsistent_pairs = 0,
		missing_todo = 0,
		missing_code = 0,
		details = {},
	}

	-- 收集所有ID
	local all_ids = {}
	for id, _ in pairs(all_todo) do
		all_ids[id] = true
	end
	for id, _ in pairs(all_code) do
		all_ids[id] = true
	end

	-- 检查每个ID
	for id, _ in pairs(all_ids) do
		report.total_checked = report.total_checked + 1

		local result = M.check_link_pair_consistency(id)
		table.insert(report.details, result)

		if not result.has_todo then
			report.missing_todo = report.missing_todo + 1
		elseif not result.has_code then
			report.missing_code = report.missing_code + 1
		elseif result.status_consistent then
			report.consistent_pairs = report.consistent_pairs + 1
		else
			report.inconsistent_pairs = report.inconsistent_pairs + 1
		end
	end

	report.summary = string.format(
		"一致性检查完成: 检查了 %d 个链接对，一致: %d，不一致: %d，缺少TODO: %d，缺少代码: %d",
		report.total_checked,
		report.consistent_pairs,
		report.inconsistent_pairs,
		report.missing_todo,
		report.missing_code
	)

	return report
end

--- 修复链接对不一致
--- @param id string 链接ID
--- @param strategy string|nil 修复策略，"latest"或"todo_first"
--- @return table 修复结果
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
		if (todo_link.updated_at or 0) >= (code_link.updated_at or 0) then
			primary, secondary = todo_link, code_link
		else
			primary, secondary = code_link, todo_link
		end
	end

	-- 同步状态
	if secondary.status ~= primary.status then
		secondary.status = primary.status
		secondary.updated_at = os.time()

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
