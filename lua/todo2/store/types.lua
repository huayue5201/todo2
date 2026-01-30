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

--- @class TodoLink
--- @field id string
--- @field type string
--- @field path string
--- @field line number
--- @field content string
--- @field created_at number           -- 创建时间
--- @field updated_at number           -- 更新时间
--- @field completed_at number|nil     -- 完成时间
--- @field status string              -- 状态：normal/urgent/waiting/completed
--- @field previous_status string|nil  -- 上一次状态
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
