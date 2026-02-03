-- lua/todo2/store/types.lua
--- @module todo2.store.types

local M = {}

--- 状态枚举
--- @enum Status
M.STATUS = {
	NORMAL = "normal", -- 正常
	URGENT = "urgent", -- 紧急
	WAITING = "waiting", -- 等待
	COMPLETED = "completed", -- 完成
}

--- 链接类型枚举
M.LINK_TYPES = {
	CODE_TO_TODO = "code_to_todo",
	TODO_TO_CODE = "todo_to_code",
}

--- 状态流转规则定义
M.STATE_TRANSITIONS = {
	-- 允许的状态转换
	-- from_status -> {to_status1, to_status2, ...}
	[M.STATUS.NORMAL] = { M.STATUS.URGENT, M.STATUS.WAITING, M.STATUS.COMPLETED },
	[M.STATUS.URGENT] = { M.STATUS.NORMAL, M.STATUS.WAITING, M.STATUS.COMPLETED },
	[M.STATUS.WAITING] = { M.STATUS.NORMAL, M.STATUS.URGENT, M.STATUS.COMPLETED },
	[M.STATUS.COMPLETED] = { M.STATUS.NORMAL, M.STATUS.URGENT, M.STATUS.WAITING },
}

--- 活跃状态列表
M.ACTIVE_STATUSES = {
	[M.STATUS.NORMAL] = true,
	[M.STATUS.URGENT] = true,
	[M.STATUS.WAITING] = true,
}

--- @class TodoLink
--- @field id string
--- @field type string
--- @field path string
--- @field line number
--- @field content string
--- @field created_at number
--- @field updated_at number
--- @field completed_at number|nil
--- @field status string
--- @field previous_status string|nil
--- @field sync_version number  -- 新增：同步版本号
--- @field active boolean
--- @field context table|nil

--- @class ContextFingerprint
--- @field hash string
--- @field struct string|nil
--- @field n_prev string
--- @field n_curr string
--- @field n_next string
--- @field window_hash string

--- @class Context
--- @field raw table
--- @field fingerprint ContextFingerprint

--- @class MetaData
--- @field initialized boolean
--- @field version string
--- @field created_at number
--- @field last_sync number
--- @field total_links number
--- @field project_root string

return M
