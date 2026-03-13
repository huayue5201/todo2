-- lua/todo2/status/utils.lua
--- @module todo2.status.utils

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

function M.get_color(status)
	return M.get(status).color
end

function M.get_label(status)
	return M.get(status).label
end

function M.get_highlight(status)
	return M.get(status).hl_group
end

---------------------------------------------------------------------
-- UI 层状态机（3 状态循环）
---------------------------------------------------------------------
local USER_ORDER = { "normal", "urgent", "waiting" }

function M.get_user_cycle_order()
	return USER_ORDER
end

function M.is_user_switchable(status)
	for _, s in ipairs(USER_ORDER) do
		if s == status then
			return true
		end
	end
	return false
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
-- 时间显示（兼容原始 link 和 snapshot）
---------------------------------------------------------------------
function M.get_time_display(link)
	if not link then
		return ""
	end

	-- 情况1：传入的是 snapshot 对象（包含 _store_* 字段）
	if link._store_created_at or link._store_completed_at or link._store_archived_at then
		return time_utils.get_time_display({
			created_at = link._store_created_at,
			completed_at = link._store_completed_at,
			archived_at = link._store_archived_at,
			updated_at = link._store_updated_at,
			status = link._store_status or link.status,
		}, "compact")
	end

	-- 情况2：传入的是原始 link 对象
	return time_utils.get_time_display({
		created_at = link.created_at,
		completed_at = link.completed_at,
		archived_at = link.archived_at,
		updated_at = link.updated_at,
		status = link.status,
	}, "compact")
end

---------------------------------------------------------------------
-- ⭐ snapshot-first：状态显示组件
---------------------------------------------------------------------
function M.get_display_components(link, status)
	-- ⭐ 优先 snapshot 中的 _store_status
	local s = status or (link and link._store_status) or (link and link.status) or "normal"

	local cfg = M.get(s)
	local time_str = M.get_time_display(link)

	return {
		icon = cfg.icon,
		icon_highlight = cfg.hl_group,
		time = time_str,
		time_highlight = "TodoTime",
	}
end

---------------------------------------------------------------------
-- snapshot-first：完整显示（icon + time）
---------------------------------------------------------------------
function M.get_full_display(link, status)
	local s = status or (link and link._store_status) or (link and link.status) or "normal"

	local cfg = M.get(s)
	local time_str = M.get_time_display(link)

	if time_str ~= "" then
		return string.format("%s %s", cfg.icon, time_str)
	else
		return cfg.icon
	end
end

return M
