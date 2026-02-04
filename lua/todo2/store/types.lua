-- lua/todo2/store/types.lua
--- @module todo2.store.types
--- 类型定义

local M = {}

--- 状态枚举
M.STATUS = {
	NORMAL = "normal",
	URGENT = "urgent",
	WAITING = "waiting",
	COMPLETED = "completed",
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

return M
