-- lua/todo2/store/types.lua
--- 状态与 checkbox 的映射（唯一来源），以及任务类型定义。
---
--- 状态由用户配置 `status.cycle` 定义（顺序即循环顺序），completed / archived
--- 为固定终态。每个状态落盘成一个 checkbox 字符：`- [ ]` / `- [d]` / `- [x]`，
--- 文件因此能自包含状态，不需要 store 兜底。

local M = {}

--- 状态枚举（仅固定终态；活跃状态由用户配置 status.cycle 定义）
M.STATUS = {
	COMPLETED = "completed",
	ARCHIVED = "archived",
}

--- 状态类型：complete 计入完成，incomplete 进行中，inactive 不参与进度分母
M.TYPE = {
	COMPLETE = "complete",
	INCOMPLETE = "incomplete",
	INACTIVE = "inactive",
}

--- 终态定义（不可配置）
local TERMINAL = {
	[M.STATUS.COMPLETED] = { checkbox = "x", type = M.TYPE.COMPLETE },
	[M.STATUS.ARCHIVED] = { checkbox = ">", type = M.TYPE.INACTIVE },
}

--- 终态 checkbox → 状态（终态固定，不依赖 setup）
local TERMINAL_BY_CHECKBOX = { x = M.STATUS.COMPLETED, [">"] = M.STATUS.ARCHIVED }

--- @type table<string, {checkbox: string, type: string}>
local by_status = {}
--- @type table<string, string>
local by_checkbox = {}

--- 状态定义：终态恒定存在，活跃状态来自 `status.cycle`
---@param status string|nil
---@return {checkbox: string, type: string}|nil
local function def_for(status)
	return status and (by_status[status] or TERMINAL[status]) or nil
end

local function rebuild(cycle)
	by_status = {}
	by_checkbox = {}

	for status, def in pairs(TERMINAL) do
		by_status[status] = { checkbox = def.checkbox, type = def.type }
		by_checkbox[def.checkbox] = status
	end

	local used = { [" "] = true, x = true, X = true, [">"] = true }

	--- 活跃状态没显式配置 checkbox 时，从 label 里取第一个可用字母
	---@param label string
	---@return string
	local function derive_checkbox(label)
		for ch in label:lower():gmatch("%w") do
			if not used[ch] then
				return ch
			end
		end
		error(("todo2: no free checkbox char for status %q; set status.cycle[].checkbox"):format(label))
	end

	for i, def in ipairs(cycle or {}) do
		local cb = def.checkbox
		if cb == nil then
			cb = (i == 1) and " " or derive_checkbox(def.label)
		end
		if cb ~= " " and (#cb ~= 1 or cb:match("[%[%]%s]")) then
			error(("todo2: status %q checkbox must be one char without brackets/space"):format(def.label))
		end
		if by_checkbox[cb] then
			error(("todo2: status %q reuses checkbox %q"):format(def.label, cb))
		end
		by_status[def.label] = {
			checkbox = cb,
			type = def.type or M.TYPE.INCOMPLETE,
		}
		by_checkbox[cb] = def.label
		used[cb] = true
	end
end

--- 用用户配置重建状态 ↔ checkbox 映射（setup 时调用一次）
---@param cycle table[]|nil
function M.setup(cycle)
	rebuild(cycle)
end

--- 状态类型
---@param status string|nil
---@return string
function M.get_type(status)
	local def = def_for(status)
	return def and def.type or M.TYPE.INCOMPLETE
end

--- 判断状态是否终态（completed / archived）
---@param status string
---@return boolean
function M.is_completed_status(status)
	local t = M.get_type(status)
	return t == M.TYPE.COMPLETE or t == M.TYPE.INACTIVE
end

--- 判断状态是否活跃（非终态）
---@param status string
---@return boolean
function M.is_active_status(status)
	return not M.is_completed_status(status)
end

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
---@field tags? string[]
---@field line_num number
---@field indent number
---@field checkbox string
---@field children ParsedTask[]|nil

--- 状态转 checkbox（未知状态回退为第一个活跃状态）
---@param status string|nil
---@return string
function M.status_to_checkbox(status)
	local def = def_for(status)
	return "[" .. (def and def.checkbox or " ") .. "]"
end

--- checkbox（含方括号）转状态：终态返回固定值，活跃态返回其 label，未识别返回 nil
---@param checkbox string
---@return string|nil
function M.checkbox_to_status(checkbox)
	local ch = (checkbox or ""):match("^%[(.)%]$")
	if not ch then
		return nil
	end
	return by_checkbox[ch] or TERMINAL_BY_CHECKBOX[ch]
end

--- 状态是否已注册（scripts/migrate_v2.lua 用）
---@param status string|nil
---@return boolean
function M.is_known(status)
	return def_for(status) ~= nil
end

return M
