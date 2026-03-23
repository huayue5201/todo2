-- lua/todo2/store/types.lua
--- 类型定义（简化版）

local M = {}

--- 状态枚举
M.STATUS = {
	NORMAL = "normal",
	URGENT = "urgent",
	WAITING = "waiting",
	COMPLETED = "completed",
	ARCHIVED = "archived",
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

---@class TaskCore
---@field id string
---@field content string
---@field status string
---@field previous_status string|nil
---@field content_hash string
---@field ai_executable boolean|nil
---@field tags? string[]

---@class TaskLocation
---@field path string
---@field line integer
---@field context? table
---@field context_updated_at? integer
---@field last_verified_at? integer
---@field verification_method? string
---@field confidence? number

---@class TaskRelations
---@field parent_id? string

---@class Timestamps
---@field created number
---@field updated number
---@field completed number|nil
---@field archived number|nil

---@class Task
---@field id string
---@field core TaskCore
---@field relations? TaskRelations
---@field timestamps Timestamps
---@field verified boolean
---@field locations table<string, TaskLocation>
---@field orphaned? boolean
---@field orphaned_at? number
---@field orphaned_reason? string
---@field has_missing_mark? boolean
---@field missing_mark_line? number
---@field missing_mark_block? table

---@class ParsedTask
---@field id string|nil
---@field content string
---@field tag string|nil
---@field line_num number
---@field indent number
---@field checkbox string
---@field children ParsedTask[]|nil

-- 状态到 checkbox 的严格映射
local STATUS_TO_CHECKBOX = {
	[M.STATUS.NORMAL] = "[ ]",
	[M.STATUS.COMPLETED] = "[x]",
	[M.STATUS.ARCHIVED] = "[>]",
}

-- checkbox 到状态的严格映射
local CHECKBOX_TO_STATUS = {
	["[ ]"] = M.STATUS.NORMAL,
	["[x]"] = M.STATUS.COMPLETED,
	["[>]"] = M.STATUS.ARCHIVED,
}

--- 状态转 checkbox
---@param status string
---@return string
function M.status_to_checkbox(status)
	return STATUS_TO_CHECKBOX[status] or "[ ]"
end

--- checkbox 转状态
---@param checkbox string
---@return string
function M.checkbox_to_status(checkbox)
	return CHECKBOX_TO_STATUS[checkbox] or M.STATUS.NORMAL
end

--- 判断状态是否有效
---@param status string
---@return boolean
function M.is_valid_status(status)
	return STATUS_TO_CHECKBOX[status] ~= nil
end

--- 判断状态是否活跃
---@param status string
---@return boolean
function M.is_active_status(status)
	return M.ACTIVE_STATUSES[status] == true
end

--- 判断状态是否完成
---@param status string
---@return boolean
function M.is_completed_status(status)
	return M.COMPLETED_STATUSES[status] == true
end

--- 判断状态是否归档
---@param status string
---@return boolean
function M.is_archived_status(status)
	return status == M.STATUS.ARCHIVED
end

--- 判断任务是否允许代码标记缺失
---@param status string
---@return boolean
function M.can_miss_code_marker(status)
	return status == M.STATUS.ARCHIVED
end

return M
