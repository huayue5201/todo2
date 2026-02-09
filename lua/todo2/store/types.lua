--- File: /Users/lijia/todo2/lua/todo2/store/types.lua ---
-- lua/todo2/store/types.lua
--- @module todo2.store.types
--- 类型定义

local M = {}

--- 状态枚举
M.STATUS = {
	NORMAL = "normal", -- 正常（活跃状态）
	URGENT = "urgent", -- 紧急（活跃状态）
	WAITING = "waiting", -- 等待（活跃状态）
	COMPLETED = "completed", -- 完成（复选框状态，不是状态机状态）
	ARCHIVED = "archived", -- 归档（已完成任务的扩展状态）
}

--- 链接类型枚举
M.LINK_TYPES = {
	TODO_TO_CODE = "todo_to_code",
	CODE_TO_TODO = "code_to_todo",
}

--- 活跃状态列表
M.ACTIVE_STATUSES = {
	[M.STATUS.NORMAL] = true,
	[M.STATUS.URGENT] = true,
	[M.STATUS.WAITING] = true,
}

--- 获取状态分组
--- @param status string 状态
--- @return string 分组名称
function M.get_status_group(status)
	if M.ACTIVE_STATUSES[status] then
		return "active"
	elseif status == M.STATUS.ARCHIVED then
		return "archived"
	else
		return "unknown"
	end
end

return M
