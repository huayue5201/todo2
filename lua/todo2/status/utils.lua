-- lua/todo2/status/utils.lua
--- @module todo2.status.utils

local M = {}

local config = require("todo2.config")
local time_utils = require("todo2.utils.time")

---------------------------------------------------------------------
-- 状态配置获取
---------------------------------------------------------------------

--- 获取单个状态定义
--- @param status string 状态名称
--- @return table 状态配置
function M.get(status)
	local definitions = config.get("status_icons") or {}
	local def = definitions[status] or definitions.normal or {}

	-- ⭐ 确保返回的配置包含所有必要字段
	return {
		icon = def.icon or "●",
		label = def.label or status, -- 使用 def.label 或回退到 status
		color = def.color or "#888888",
		hl_group = def.hl_group or "TodoStatus" .. (status:sub(1, 1):upper() .. status:sub(2)),
	}
end

--- 获取所有状态定义
--- @return table
function M.get_all()
	return config.get("status_definitions") or {}
end

---------------------------------------------------------------------
-- 状态顺序配置
---------------------------------------------------------------------

--- 获取用户可手动切换的状态顺序
function M.get_user_cycle_order()
	return config.get("status_user_order") or { "normal", "urgent", "waiting" }
end

--- 获取包含所有状态的完整顺序
function M.get_full_cycle_order()
	return config.get("status_full_order") or { "normal", "urgent", "waiting", "completed" }
end

---------------------------------------------------------------------
-- 状态属性获取
---------------------------------------------------------------------

function M.get_highlight(status)
	return M.get(status).hl_group
end

function M.get_icon(status)
	return M.get(status).icon
end

function M.get_color(status)
	return M.get(status).color
end

function M.get_label(status)
	return M.get(status).label
end

---------------------------------------------------------------------
-- 时间相关函数
---------------------------------------------------------------------

--- 获取任务应显示的时间戳
--- @param link table 链接对象
--- @return number|nil
function M.get_display_timestamp(link)
	return time_utils.get_display_timestamp(link)
end

--- 获取时间显示文本
--- @param link table 链接对象
--- @return string
function M.get_time_display(link)
	return time_utils.get_time_display(link, "compact")
end

--- 获取分离的显示组件
--- @param link table 链接对象
--- @param status string 状态
--- @return table { icon, icon_highlight, time, time_highlight }
function M.get_display_components(link, status)
	status = status or (link and link.status) or "normal"
	local cfg = M.get(status)
	local time_str = M.get_time_display(link)

	return {
		icon = cfg.icon,
		icon_highlight = cfg.hl_group,
		time = time_str,
		time_highlight = "TodoTime",
	}
end

--- 获取简短的完整显示字符串
function M.get_full_display(link, status)
	local cfg = M.get(status or link.status)
	local time_str = M.get_time_display(link)
	if time_str and time_str ~= "" then
		return string.format("%s %s", cfg.icon, time_str)
	else
		return cfg.icon
	end
end

---------------------------------------------------------------------
-- 状态可切换判断
---------------------------------------------------------------------

--- 判断状态是否在用户可手动切换的范围内
--- @param status string
--- @return boolean
function M.is_user_switchable(status)
	local order = M.get_user_cycle_order()
	for _, s in ipairs(order) do
		if s == status then
			return true
		end
	end
	return false
end

--- 获取下一个用户状态
--- @param current_status string
--- @return string
function M.get_next_user_status(current_status)
	local order = M.get_user_cycle_order()
	for i, status in ipairs(order) do
		if status == current_status then
			return order[i % #order + 1]
		end
	end
	return order[1]
end

--- 获取下一个完整状态
--- @param current_status string
--- @return string
function M.get_next_status(current_status)
	local order = M.get_full_cycle_order()
	for i, status in ipairs(order) do
		if status == current_status then
			return order[i % #order + 1]
		end
	end
	return order[1]
end

return M
