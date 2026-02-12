-- lua/todo2/status/utils.lua
--- @module todo2.status.utils
--- @brief 状态工具函数模块（配置读取、状态顺序、显示组件）

local M = {}

local config = require("todo2.config")
-- ⭐ 复用统一时间工具
local time_utils = require("todo2.utils.time")

---------------------------------------------------------------------
-- 状态配置获取（完全依赖 config.lua）
---------------------------------------------------------------------

--- 获取单个状态定义
--- @param status string 状态名称
--- @return table 状态配置
function M.get(status)
	local definitions = config.get("status_definitions") or {}
	return definitions[status] or definitions.normal or { icon = "●", label = status, color = "#888888" }
end

--- 获取所有状态定义
--- @return table
function M.get_all()
	return config.get("status_definitions") or {}
end

---------------------------------------------------------------------
-- 状态顺序配置（统一从 config 读取，无默认硬编码）
---------------------------------------------------------------------

--- 获取用户可手动切换的状态顺序（用于循环切换）
function M.get_user_cycle_order()
	return config.get("status_user_order") or { "normal", "urgent", "waiting" }
end

--- 获取包含所有状态的完整顺序（用于 toggle_line 等）
function M.get_full_cycle_order()
	return config.get("status_full_order") or { "normal", "urgent", "waiting", "completed" }
end

---------------------------------------------------------------------
-- 状态属性获取（纯查询）
---------------------------------------------------------------------

function M.get_highlight(status)
	return M.get(status).hl_group or "TodoStatusNormal"
end

function M.get_icon(status)
	return M.get(status).icon or "●"
end

function M.get_color(status)
	return M.get(status).color or "#ff6b6b"
end

---------------------------------------------------------------------
-- ⭐ 时间相关函数 —— 完全委托给 utils/time.lua
---------------------------------------------------------------------

--- 获取任务应显示的时间戳（委托）
--- @param link table 链接对象
--- @return number|nil
function M.get_display_timestamp(link)
	return time_utils.get_display_timestamp(link)
end

--- 获取时间显示文本（紧凑格式，委托）
--- @param link table 链接对象
--- @return string
function M.get_time_display(link)
	return time_utils.get_time_display(link, "compact")
end

--- 获取分离的显示组件（图标 + 时间，分别可高亮）
--- @param link table 链接对象
--- @param status string 状态（通常取 link.status）
--- @return table { icon, icon_highlight, time, time_highlight }
function M.get_display_components(link, status)
	status = status or (link and link.status) or "normal"
	local cfg = M.get(status)
	local time_str = M.get_time_display(link) -- 已委托

	return {
		icon = cfg.icon or "",
		icon_highlight = cfg.hl_group or "TodoStatus" .. (status:sub(1, 1):upper() .. status:sub(2)),
		time = time_str,
		time_highlight = "Comment", -- 可配置
	}
end

--- 获取简短的完整显示字符串（图标 + 时间）
function M.get_full_display(link, status)
	local cfg = M.get(status or link.status)
	local time_str = M.get_time_display(link)
	if time_str and time_str ~= "" then
		return string.format("%s %s", cfg.icon, time_str)
	else
		return cfg.icon or ""
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

return M
