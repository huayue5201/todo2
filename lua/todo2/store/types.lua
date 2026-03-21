-- lua/todo2/store/types.lua
--- 类型定义（简化版：只保留实际使用的复选框映射）

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

---@class Timestamps
---@field created number
---@field updated number
---@field completed number|nil
---@field archived number|nil

---@class Task
---@field id string
---@field core TaskCore
---@field timestamps Timestamps
---@field children Task[]|nil

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
--- @param status string
--- @return string
function M.status_to_checkbox(status)
	return STATUS_TO_CHECKBOX[status] or "[ ]"
end

--- checkbox 转状态
--- @param checkbox string
--- @return string
function M.checkbox_to_status(checkbox)
	return CHECKBOX_TO_STATUS[checkbox] or M.STATUS.NORMAL
end

--- 判断状态是否有效
--- @param status string
--- @return boolean
function M.is_valid_status(status)
	return STATUS_TO_CHECKBOX[status] ~= nil
end

--- 判断状态是否活跃
--- @param status string
--- @return boolean
function M.is_active_status(status)
	return M.ACTIVE_STATUSES[status] == true
end

--- 判断状态是否完成
--- @param status string
--- @return boolean
function M.is_completed_status(status)
	return M.COMPLETED_STATUSES[status] == true
end

--- 判断状态是否归档
--- @param status string
--- @return boolean
function M.is_archived_status(status)
	return status == M.STATUS.ARCHIVED
end

--- 判断任务是否允许代码标记缺失
--- @param status string
--- @return boolean
function M.can_miss_code_marker(status)
	return status == M.STATUS.ARCHIVED
end

--- 验证 TODO 行与存储状态是否一致
--- @param line string TODO行内容
--- @param stored_status string 存储中的状态
--- @return boolean, string
function M.validate_todo_line(line, stored_status)
	local checkbox = line:match("%[(.)%]")
	if not checkbox then
		return false, "不是有效的任务行"
	end

	local full_checkbox = "[" .. checkbox .. "]"

	if full_checkbox == "[ ]" or full_checkbox == "[x]" or full_checkbox == "[>]" then
		local line_status = CHECKBOX_TO_STATUS[full_checkbox]
		if line_status ~= stored_status then
			return false,
				string.format("状态不一致: 文件显示 %s, 存储记录为 %s", line_status, stored_status)
		end
		return true, "一致"
	end

	return true, "由 status 模块处理"
end

return M
