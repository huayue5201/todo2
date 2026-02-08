-- lua/todo2/store/types.lua
--- @module todo2.store.types
--- 类型定义（扩展归档状态）

local M = {}

--- 状态枚举（五态）
M.STATUS = {
	NORMAL = "normal", -- 正常
	URGENT = "urgent", -- 紧急
	WAITING = "waiting", -- 等待
	COMPLETED = "completed", -- 完成
	ARCHIVED = "archived", -- 归档
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

--- 完成状态列表
M.COMPLETED_STATUSES = {
	[M.STATUS.COMPLETED] = true,
}

--- 归档状态列表
M.ARCHIVED_STATUSES = {
	[M.STATUS.ARCHIVED] = true,
}

--- 获取状态所属分组
--- @param status string 状态
--- @return string 分组名称
function M.get_status_group(status)
	if M.ACTIVE_STATUSES[status] then
		return "active"
	elseif M.COMPLETED_STATUSES[status] then
		return "completed"
	elseif M.ARCHIVED_STATUSES[status] then
		return "archived"
	end
	return "active"
end

return M
