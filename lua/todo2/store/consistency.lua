-- lua/todo2/store/consistency.lua
--- @module todo2.store.consistency
--- 一致性检查（修复版：添加状态校准）

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local types = require("todo2.store.types")
local verification = require("todo2.store.verification")
local lifecycle = require("todo2.store.link_lifecycle")

--- 检查链接对一致性
--- @param id string 链接ID
--- @return table 检查结果
function M.check_link_pair_consistency(id)
	-- 直接使用 lifecycle.check_pair_consistency
	local todo_link = store.get_key("todo.links.todo." .. id)
	local code_link = store.get_key("todo.links.code." .. id)

	local consistent, diff = lifecycle.check_pair_consistency(todo_link, code_link)

	-- 包装成需要的格式
	return {
		id = id,
		has_todo = todo_link ~= nil,
		has_code = code_link ~= nil,
		consistent = consistent,
		details = diff,
	}
end

-- ⭐ 新增：验证归档状态一致性
function M.verify_archive_consistency(id)
	local snapshot = link.get_archive_snapshot(id)
	local todo_link = link.get_todo(id, { verify_line = true })
	local core_status = require("todo2.core.status")

	-- ⭐ 校准活跃状态
	if todo_link then
		todo_link = verification.calibrate_link_active_status(todo_link)
	end

	local result = {
		id = id,
		consistent = true,
		issues = {},
		has_snapshot = snapshot ~= nil,
		has_todo = todo_link ~= nil,
	}

	-- 检查快照是否存在
	if not snapshot then
		result.consistent = false
		table.insert(result.issues, "缺少归档快照")
		return result
	end

	-- 检查快照完整性
	if not snapshot.todo or not snapshot.todo.status then
		result.consistent = false
		table.insert(result.issues, "归档快照不完整")
	end

	-- 如果任务存在，检查状态流转合法性
	if todo_link then
		-- 如果任务已恢复，检查是否符合状态流转
		if todo_link.status ~= types.STATUS.ARCHIVED then
			local allowed = core_status.is_transition_allowed(snapshot.todo.status, todo_link.status)
			if not allowed then
				result.consistent = false
				table.insert(
					result.issues,
					string.format("非法状态流转: %s → %s", snapshot.todo.status, todo_link.status)
				)
			end
		end

		-- 检查待恢复状态
		if todo_link.pending_restore_status then
			if not types.is_active_status(todo_link.pending_restore_status) then
				result.consistent = false
				table.insert(
					result.issues,
					string.format("无效的待恢复状态: %s", todo_link.pending_restore_status)
				)
			end
		end
	end

	-- 检查归档前状态的合法性
	if snapshot.todo and snapshot.todo.status then
		if not core_status.is_transition_allowed(snapshot.todo.status, types.STATUS.ARCHIVED) then
			result.consistent = false
			table.insert(result.issues, string.format("归档前状态 %s 不能直接归档", snapshot.todo.status))
		end
	end

	-- 生成摘要
	if #result.issues > 0 then
		result.summary = string.format("发现 %d 个问题: %s", #result.issues, table.concat(result.issues, "; "))
	else
		result.summary = "归档状态一致"
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
		archive_issues = 0,
		active_inconsistent = 0, -- ⭐ 新增：活跃状态不一致计数
		deleted_inconsistent = 0, -- ⭐ 新增：删除状态不一致计数
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
		elseif result.status_consistent and result.active_consistent and result.deleted_consistent then
			report.consistent_pairs = report.consistent_pairs + 1
		else
			report.inconsistent_pairs = report.inconsistent_pairs + 1
			if not result.active_consistent then
				report.active_inconsistent = report.active_inconsistent + 1
			end
			if not result.deleted_consistent then
				report.deleted_inconsistent = report.deleted_inconsistent + 1
			end
		end

		-- 检查归档状态
		local archive_check = M.verify_archive_consistency(id)
		if not archive_check.consistent then
			report.archive_issues = report.archive_issues + 1
		end
	end

	report.summary = string.format(
		"一致性检查完成: 检查了 %d 个链接对，一致: %d，不一致: %d (活跃: %d, 删除: %d)，缺少TODO: %d，缺少代码: %d，归档问题: %d",
		report.total_checked,
		report.consistent_pairs,
		report.inconsistent_pairs,
		report.active_inconsistent,
		report.deleted_inconsistent,
		report.missing_todo,
		report.missing_code,
		report.archive_issues
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

	-- ⭐ 校准活跃状态
	todo_link = verification.calibrate_link_active_status(todo_link)
	code_link = verification.calibrate_link_active_status(code_link)

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

	local changes = {}

	-- 同步状态
	if secondary.status ~= primary.status then
		secondary.status = primary.status
		table.insert(changes, "状态")
	end

	-- ⭐ 同步活跃状态
	if secondary.active ~= primary.active then
		secondary.active = primary.active
		table.insert(changes, "活跃状态")
	end

	-- ⭐ 同步删除状态
	if secondary.deleted_at ~= primary.deleted_at then
		secondary.deleted_at = primary.deleted_at
		table.insert(changes, "删除状态")
	end

	-- 如果有变化，更新时间戳并保存
	if #changes > 0 then
		secondary.updated_at = os.time()

		if secondary.type == "todo_to_code" then
			store.set_key(todo_key, secondary)
		else
			store.set_key(code_key, secondary)
		end

		return {
			repaired = true,
			message = "已修复: " .. table.concat(changes, ", "),
			changes = changes,
		}
	end

	return {
		repaired = false,
		message = "无需修复",
	}
end

return M
