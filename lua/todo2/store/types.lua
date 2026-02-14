-- lua/todo2/store/types.lua
--- @module todo2.store.types
--- 类型定义（增强版：支持状态与checkbox双向映射）

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

-- ⭐ 状态到 checkbox 的严格映射
local STATUS_TO_CHECKBOX = {
	[M.STATUS.NORMAL] = "[ ]",
	[M.STATUS.URGENT] = "[!]",
	[M.STATUS.WAITING] = "[?]",
	[M.STATUS.COMPLETED] = "[x]",
	[M.STATUS.ARCHIVED] = "[>]",
}

-- ⭐ checkbox 到状态的严格映射
local CHECKBOX_TO_STATUS = {
	["[ ]"] = M.STATUS.NORMAL,
	["[!]"] = M.STATUS.URGENT,
	["[?]"] = M.STATUS.WAITING,
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

--- 验证 TODO 行与存储状态是否一致
--- @param line string TODO行内容
--- @param stored_status string 存储中的状态
--- @return boolean, string
function M.validate_todo_line(line, stored_status)
	local checkbox = line:match("%[(.)%]")
	if not checkbox then
		return false, "不是有效的任务行"
	end

	-- 将单个字符转换为完整 checkbox
	local full_checkbox = "[" .. checkbox .. "]"
	local line_status = CHECKBOX_TO_STATUS[full_checkbox]

	if not line_status then
		return false, "未知的 checkbox 状态"
	end

	if line_status ~= stored_status then
		return false, string.format("状态不一致: 文件显示 %s, 存储记录为 %s", line_status, stored_status)
	end

	return true, "一致"
end

return M
