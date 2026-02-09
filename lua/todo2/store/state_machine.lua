--- File: /Users/lijia/todo2/lua/todo2/store/state_machine.lua ---
-- lua/todo2/store/state_machine.lua
--- @module todo2.store.state_machine
--- 活跃状态状态机：只管理活跃状态之间的流转

local M = {}

local types = require("todo2.store.types")

--- 活跃状态流转规则（任意两个活跃状态之间都可以切换）
--- 因为活跃状态只是优先级/标签，没有严格的流转限制
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

--- 检查状态是否是活跃状态
--- @param status string 状态
--- @return boolean
function M.is_active_status(status)
	return status == types.STATUS.NORMAL or status == types.STATUS.URGENT or status == types.STATUS.WAITING
end

--- 检查状态是否是已完成状态
--- @param status string 状态
--- @return boolean
function M.is_completed_status(status)
	return status == types.STATUS.COMPLETED or status == types.STATUS.ARCHIVED
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

	-- 只能更新未完成任务的活跃状态
	if link.completed then
		return false, "已完成的任务不能设置活跃状态"
	end

	-- 只能设置为活跃状态
	if not M.is_active_status(new_status) then
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
	if not M.is_active_status(new_status) and not M.is_completed_status(new_status) then
		return false, "无效的状态"
	end

	-- 如果已经是归档状态，只能取消归档，不能直接修改状态
	if link.archived and new_status ~= types.STATUS.ARCHIVED then
		return false, "归档的链接需要先取消归档"
	end

	-- 如果是完成状态，需要检查是否可以重新打开
	if link.completed and M.is_active_status(new_status) then
		return true, "需要先重新打开任务"
	end

	return true, ""
end

return M
