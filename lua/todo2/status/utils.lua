-- lua/todo2/status/utils.lua
--- @module todo2.status.utils
--- @brief 状态工具函数模块

local M = {}

-- 导入配置
local config = require("todo2.config")

---------------------------------------------------------------------
-- 状态配置获取
---------------------------------------------------------------------

--- 获取状态定义
--- @param status string 状态名称
--- @return table 状态配置
function M.get(status)
	local definitions = config.get("status_definitions") or {}
	return definitions[status] or definitions.normal or {}
end

--- 获取所有状态定义
--- @return table 所有状态配置
function M.get_all()
	return config.get("status_definitions") or {}
end

---------------------------------------------------------------------
-- 状态循环管理
---------------------------------------------------------------------

--- 用户可手动切换的状态循环（移除 completed）
function M.get_user_cycle_order()
	return config.get("status_user_order") or { "normal", "urgent", "waiting" }
end

--- 包含所有状态的完整循环（包括完成状态）
function M.get_full_cycle_order()
	return config.get("status_full_order") or { "normal", "urgent", "waiting", "completed" }
end

--- 用户手动切换状态时使用的函数
function M.get_next_user_status(current_status)
	local order = M.get_user_cycle_order()
	local current_index = 1

	for i, status in ipairs(order) do
		if status == current_status then
			current_index = i
			break
		end
	end

	local next_index = current_index % #order + 1
	return order[next_index]
end

--- 完整的状态获取下一个（用于toggle_line时使用）
function M.get_next_status(current_status)
	local order = M.get_full_cycle_order()
	local current_index = 1

	for i, status in ipairs(order) do
		if status == current_status then
			current_index = i
			break
		end
	end

	local next_index = current_index % #order + 1
	return order[next_index]
end

---------------------------------------------------------------------
-- 状态属性获取
---------------------------------------------------------------------

function M.get_highlight(status)
	local config = M.get(status)
	return config.hl_group or "TodoStatusNormal"
end

function M.get_icon(status)
	local config = M.get(status)
	return config.icon or "●"
end

function M.get_color(status)
	local config = M.get(status)
	return config.color or "#ff6b6b"
end

---------------------------------------------------------------------
-- 时间相关函数
---------------------------------------------------------------------

function M.get_display_timestamp(link)
	if not link then
		return nil
	end

	-- 完成状态显示完成时间，其他状态显示最后更新时间
	if link.status == "completed" and link.completed_at then
		return link.completed_at
	else
		return link.updated_at or link.created_at
	end
end

function M.get_time_display(link)
	local timestamp = M.get_display_timestamp(link)
	if not timestamp then
		return ""
	end

	-- 简单的时间格式化
	local timestamp_format = config.get("timestamp_format") or "%Y/%m/%d %H:%M"
	local success, result = pcall(function()
		if type(timestamp) == "number" then
			return os.date(timestamp_format, timestamp)
		else
			return tostring(timestamp)
		end
	end)

	return success and result or ""
end

function M.get_full_display(link, status)
	local cfg = M.get(status)
	local time_str = M.get_time_display(link)

	if time_str and time_str ~= "" then
		return string.format("%s %s", cfg.icon, time_str)
	else
		return cfg.icon
	end
end

--- 获取时间戳高亮组
function M.get_time_highlight()
	return "Comment" -- 可以使用配置中的颜色
end

--- 获取分离的显示组件（用于需要分别高亮的情况）
function M.get_display_components(link, status)
	local cfg = M.get(status)
	local time_str = M.get_time_display(link)

	return {
		icon = cfg.icon,
		icon_highlight = cfg.hl_group or "TodoStatus" .. (status:sub(1, 1):upper() .. status:sub(2)),
		time = time_str,
		time_highlight = M.get_time_highlight(),
	}
end

--- 判断状态是否在用户可切换范围内
function M.is_user_switchable(status)
	local user_statuses = M.get_user_cycle_order()
	for _, s in ipairs(user_statuses) do
		if s == status then
			return true
		end
	end
	return false
end

return M
