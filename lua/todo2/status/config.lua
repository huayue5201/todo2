--- File: /Users/lijia/todo2/lua/todo2/status/config.lua ---
-- lua/todo2/status/config.lua
--- @module todo2.status.config
--- @brief 状态配置管理

local M = {}

local default_config = {
	normal = {
		icon = " 󱐿",
		color = "#51cf66", -- 绿色
		label = "正常",
		hl_group = "TodoStatusNormal",
		description = "常规任务",
	},
	urgent = {
		icon = " 󱐿",
		color = "#ff6b6b", -- 红色
		label = "紧急",
		hl_group = "TodoStatusUrgent",
		description = "需要优先处理",
	},
	waiting = {
		icon = " 󱐿",
		color = "#ffd43b", -- 黄色
		label = "等待",
		hl_group = "TodoStatusWaiting",
		description = "等待外部依赖",
	},
	-- 注意：移除了 completed 状态，它只能通过 toggle_line 自动设置
	completed = {
		icon = " 󱐿",
		color = "#868e96", -- 灰色
		label = "完成",
		hl_group = "TodoStatusCompleted",
		description = "已完成的任务",
	},
}

---------------------------------------------------------------------
-- 公共函数
---------------------------------------------------------------------

function M.get(status)
	return default_config[status] or default_config.normal
end

function M.get_all()
	return default_config
end

-- ⭐ 用户可手动切换的状态循环（移除 completed）
function M.get_user_cycle_order()
	return { "normal", "urgent", "waiting" }
end

-- ⭐ 包含所有状态的完整循环（包括完成状态）
function M.get_full_cycle_order()
	return { "normal", "urgent", "waiting", "completed" }
end

-- ⭐ 用户手动切换状态时使用的函数
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

-- ⭐ 完整的状态获取下一个（用于toggle_line时使用）
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
	local time_util = require("todo2.utils.time")
	local timestamp = M.get_display_timestamp(link)
	if not timestamp then
		return ""
	end
	return time_util.format_compact(timestamp)
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

-- ⭐ 新增：判断状态是否在用户可切换范围内
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
