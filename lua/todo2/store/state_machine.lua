--- File: /Users/lijia/todo2/lua/todo2/store/state_machine.lua ---
-- lua/todo2/store/state_machine.lua
--- @module todo2.store.state_machine
--- 状态机：只管理活跃状态之间的流转

local M = {}

local types = require("todo2.store.types")

--- 活跃状态流转规则（任意两个活跃状态之间都可以切换）
local ACTIVE_STATUS_FLOW = {
	[types.STATUS.NORMAL] = {
		next = { types.STATUS.URGENT, types.STATUS.WAITING },
	},
	[types.STATUS.URGENT] = {
		next = { types.STATUS.NORMAL, types.STATUS.WAITING },
	},
	[types.STATUS.WAITING] = {
		next = { types.STATUS.NORMAL, types.STATUS.URGENT },
	},
}

--- 完整状态流转规则
local FULL_STATUS_FLOW = {
	[types.STATUS.NORMAL] = {
		next = { types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.COMPLETED },
	},
	[types.STATUS.URGENT] = {
		next = { types.STATUS.NORMAL, types.STATUS.WAITING, types.STATUS.COMPLETED },
	},
	[types.STATUS.WAITING] = {
		next = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.COMPLETED },
	},
	[types.STATUS.COMPLETED] = {
		next = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.ARCHIVED },
	},
	[types.STATUS.ARCHIVED] = {
		next = { types.STATUS.COMPLETED },
	},
}

--- 检查状态是否是活跃状态
--- @param status string 状态
--- @return boolean
function M.is_active_status(status)
	return types.is_active_status(status)
end

--- 检查状态是否是已完成状态
--- @param status string 状态
--- @return boolean
function M.is_completed_status(status)
	return types.is_completed_status(status)
end

--- 检查状态是否是归档状态
--- @param status string 状态
--- @return boolean
function M.is_archived_status(status)
	return types.is_archived_status(status)
end

--- 检查状态流转是否允许
--- @param current_status string 当前状态
--- @param new_status string 新状态
--- @return boolean 是否允许
function M.is_transition_allowed(current_status, new_status)
	local flow = FULL_STATUS_FLOW[current_status]
	if not flow then
		return false
	end

	for _, allowed in ipairs(flow.next) do
		if new_status == allowed then
			return true
		end
	end

	return false
end

--- 获取可用的状态流转列表
--- @param current_status string 当前状态
--- @return table 可流转到的状态列表
function M.get_available_transitions(current_status)
	local flow = FULL_STATUS_FLOW[current_status]
	if not flow then
		return {}
	end
	return flow.next
end

--- 获取下一个用户状态（用于循环切换）
--- @param current_status string 当前状态
--- @return string 下一个状态
function M.get_next_user_status(current_status)
	local order = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING }

	for i, status in ipairs(order) do
		if current_status == status then
			return order[i % #order + 1]
		end
	end

	-- 如果当前不是活跃状态，返回正常状态
	return types.STATUS.NORMAL
end

--- 获取活跃状态的显示信息
--- @param status string 活跃状态
--- @return table 显示信息
function M.get_status_display_info(status)
	local info = {
		[types.STATUS.NORMAL] = {
			name = "正常",
			icon = "○",
			color = "Normal",
			description = "普通优先级任务",
		},
		[types.STATUS.URGENT] = {
			name = "紧急",
			icon = "⚠",
			color = "Error",
			description = "需要尽快处理的任务",
		},
		[types.STATUS.WAITING] = {
			name = "等待",
			icon = "⌛",
			color = "WarningMsg",
			description = "等待外部依赖或条件的任务",
		},
		[types.STATUS.COMPLETED] = {
			name = "完成",
			icon = "✓",
			color = "Comment",
			description = "已完成的任务",
		},
		[types.STATUS.ARCHIVED] = {
			name = "归档",
			icon = "📁",
			color = "Comment",
			description = "已归档的任务",
		},
	}

	return info[status] or {
		name = "未知",
		icon = "?",
		color = "Comment",
		description = "未知状态",
	}
end

--- 检查是否可以更新活跃状态
--- @param link table 链接对象
--- @param new_status string 新状态
--- @return boolean, string 是否可以更新，错误消息
function M.can_update_active_status(link, new_status)
	if not link then
		return false, "链接不存在"
	end

	-- 只能更新活跃任务的活跃状态
	if types.is_completed_status(link.status) then
		return false, "已完成的任务不能设置活跃状态"
	end

	-- 只能设置为活跃状态
	if not types.is_active_status(new_status) then
		return false, "只能设置为活跃状态：normal, urgent 或 waiting"
	end

	return true, ""
end

--- 获取所有活跃状态列表
--- @return table 活跃状态列表
function M.get_all_active_statuses()
	return {
		types.STATUS.NORMAL,
		types.STATUS.URGENT,
		types.STATUS.WAITING,
	}
end

--- 检查链接是否可以设置为指定状态
--- @param link table 链接对象
--- @param new_status string 新状态
--- @return boolean, string 是否可以设置，错误消息
function M.can_set_status(link, new_status)
	if not link then
		return false, "链接不存在"
	end

	-- 如果链接已被软删除，不能修改状态
	if link.active == false then
		return false, "链接已被删除，不能修改状态"
	end

	-- 检查状态是否有效
	if not types.is_active_status(new_status) and not types.is_completed_status(new_status) then
		return false, "无效的状态"
	end

	-- 如果是归档状态，只能取消归档，不能直接修改状态
	if link.status == types.STATUS.ARCHIVED and new_status ~= types.STATUS.ARCHIVED then
		return false, "归档的链接需要先取消归档"
	end

	-- 如果是完成状态，需要检查是否可以重新打开
	if types.is_completed_status(link.status) and types.is_active_status(new_status) then
		return true, "需要先重新打开任务"
	end

	return true, ""
end

return M
