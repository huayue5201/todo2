-- lua/todo2/store/types.lua
--- @module todo2.store.types
--- 类型定义

local M = {}

--- 状态枚举
M.STATUS = {
	NORMAL = "normal", -- 正常（活跃状态）
	URGENT = "urgent", -- 紧急（活跃状态）
	WAITING = "waiting", -- 等待（活跃状态）
	COMPLETED = "completed", -- 完成
	ARCHIVED = "archived", -- 归档
}

--- 活跃状态列表
M.ACTIVE_STATUSES = {
	[M.STATUS.NORMAL] = true,
	[M.STATUS.URGENT] = true,
	[M.STATUS.WAITING] = true,
}

--- 完成状态列表
M.COMPLETED_STATUSES = {
	[M.STATUS.COMPLETED] = true,
	[M.STATUS.ARCHIVED] = true,
}

--- 链接类型枚举
M.LINK_TYPES = {
	TODO_TO_CODE = "todo_to_code",
	CODE_TO_TODO = "code_to_todo",
}

--- 判断状态是否活跃
--- @param status string 状态
--- @return boolean
function M.is_active_status(status)
	return M.ACTIVE_STATUSES[status] == true
end

--- 判断状态是否完成
--- @param status string 状态
--- @return boolean
function M.is_completed_status(status)
	return M.COMPLETED_STATUSES[status] == true
end

--- 判断状态是否归档
--- @param status string 状态
--- @return boolean
function M.is_archived_status(status)
	return status == M.STATUS.ARCHIVED
end

--- 判断任务是否允许代码标记缺失
--- @param status string 状态
--- @return boolean
function M.can_miss_code_marker(status)
	-- 归档状态允许代码标记缺失
	return status == M.STATUS.ARCHIVED
end

return M
