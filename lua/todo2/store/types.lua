-- lua/todo2/store/types.lua
--- 类型定义（简化版）

local M = {}

--- 状态枚举（仅固定终态；活跃状态由用户配置 status.cycle 定义）
M.STATUS = {
	COMPLETED = "completed",
	ARCHIVED = "archived",
}

--- 判断状态是否完成（completed / archived）
---@param status string
---@return boolean
function M.is_completed_status(status)
	return status == M.STATUS.COMPLETED or status == M.STATUS.ARCHIVED
end

--- 判断状态是否活跃（非完成/归档）
---@param status string
---@return boolean
function M.is_active_status(status)
	return not M.is_completed_status(status)
end

--- 链接类型枚举
M.LINK_TYPES = {
	TODO_TO_CODE = "todo_to_code",
	CODE_TO_TODO = "code_to_todo",
}

---@class TaskCore
---@field content string
---@field status string
---@field previous_status string|nil
---@field tags? string[]

---@class TaskLocation
---@field path string
---@field line integer
---@field context? table

---@class Timestamps
---@field created number
---@field updated number
---@field completed number|nil
---@field archived number|nil

---@class Task
---@field id string
---@field core TaskCore
---@field timestamps Timestamps
---@field locations table<string, TaskLocation>

---@class ParsedTask
---@field id string|nil
---@field content string
---@field tag string|nil
---@field line_num number
---@field indent number
---@field checkbox string
---@field children ParsedTask[]|nil

-- 状态到 checkbox 的映射（活跃状态统一为 [ ]，具体 label 由 core.status 决定）
local STATUS_TO_CHECKBOX = {
	[M.STATUS.COMPLETED] = "[x]",
	[M.STATUS.ARCHIVED] = "[>]",
}

-- checkbox 到状态的映射（活跃 checkbox [ ] 返回 nil，具体默认值由 core.status 决定）
local CHECKBOX_TO_STATUS = {
	["[x]"] = M.STATUS.COMPLETED,
	["[>]"] = M.STATUS.ARCHIVED,
}

--- 状态转 checkbox
---@param status string
---@return string
function M.status_to_checkbox(status)
	return STATUS_TO_CHECKBOX[status] or "[ ]"
end

--- checkbox 转状态（活跃返回 nil）
---@param checkbox string
---@return string|nil
function M.checkbox_to_status(checkbox)
	return CHECKBOX_TO_STATUS[checkbox]
end

return M
