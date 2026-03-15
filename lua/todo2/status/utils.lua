-- lua/todo2/status/utils.lua
-- 精简版：仅保留 UI 层需要的状态图标、标签、循环顺序、时间显示

local M = {}

local config = require("todo2.config")
local time_utils = require("todo2.utils.time")

---------------------------------------------------------------------
-- 状态配置（图标 / label / 颜色）
---------------------------------------------------------------------
function M.get(status)
	local definitions = config.get("status_icons") or {}
	local def = definitions[status] or definitions.normal or {}

	return {
		icon = def.icon or "●",
		label = def.label or status,
		color = def.color or "#888888",
		hl_group = def.hl_group or ("TodoStatus" .. status:gsub("^%l", string.upper)),
	}
end

function M.get_icon(status)
	return M.get(status).icon
end

function M.get_label(status)
	return M.get(status).label
end

---------------------------------------------------------------------
-- UI 层状态机（normal → urgent → waiting）
---------------------------------------------------------------------
local USER_ORDER = { "normal", "urgent", "waiting" }

function M.get_user_cycle_order()
	return USER_ORDER
end

function M.get_next_user_status(current)
	for i, s in ipairs(USER_ORDER) do
		if s == current then
			return USER_ORDER[i % #USER_ORDER + 1]
		end
	end
	return USER_ORDER[1]
end

---------------------------------------------------------------------
-- 时间显示（用于菜单右侧）
---------------------------------------------------------------------
function M.get_time_display(link)
	if not link then
		return ""
	end

	return time_utils.get_time_display({
		created_at = link.created_at,
		completed_at = link.completed_at,
		archived_at = link.archived_at,
		updated_at = link.updated_at,
		status = link.status,
	}, "compact")
end

---------------------------------------------------------------------
-- UI 显示组件（图标 + 时间）
---------------------------------------------------------------------
function M.get_display_components(link, status)
	local s = status or (link and link.status) or "normal"
	local cfg = M.get(s)
	local time_str = M.get_time_display(link)

	return {
		icon = cfg.icon,
		icon_highlight = cfg.hl_group,
		time = time_str,
		time_highlight = "TodoTime",
	}
end

return M
