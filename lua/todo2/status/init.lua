-- lua/todo2/status/init.lua
--- @module todo2.status
--- @brief 状态管理模块入口（只处理状态显示和UI交互）

local M = {}

---------------------------------------------------------------------
-- 子模块加载
---------------------------------------------------------------------
local utils = require("todo2.status.utils")
local highlights = require("todo2.status.highlights")
local ui = require("todo2.status.ui")

---------------------------------------------------------------------
-- 配置API（转发到utils模块）
---------------------------------------------------------------------

function M.get_config(status)
	return utils.get(status)
end

function M.get_all_configs()
	return utils.get_all()
end

function M.get_cycle_order()
	return utils.get_user_cycle_order()
end

function M.is_user_switchable(status)
	return utils.is_user_switchable(status)
end

---------------------------------------------------------------------
-- 显示API（转发到utils模块）
---------------------------------------------------------------------

function M.get_status_display(link)
	return utils.get_full_display(link)
end

function M.get_time_display(link)
	return utils.get_time_display(link)
end

function M.get_display_components(link)
	return utils.get_display_components(link)
end

---------------------------------------------------------------------
-- UI交互API（转发到ui模块）
---------------------------------------------------------------------

function M.cycle_status()
	return ui.cycle_status()
end

function M.show_status_menu()
	return ui.show_status_menu()
end

function M.has_status_mark()
	return ui.has_status_mark()
end

function M.get_current_status()
	return ui.get_current_status()
end

function M.get_current_status_config()
	return ui.get_current_status_config()
end

function M.mark_completed()
	return ui.mark_completed()
end

function M.reopen_link()
	return ui.reopen_link()
end

---------------------------------------------------------------------
-- 高亮API（转发到highlights模块）
---------------------------------------------------------------------

function M.get_highlight(status)
	return highlights.get_highlight(status)
end

function M.get_time_highlight()
	return highlights.get_time_highlight()
end

function M.setup_highlights()
	return highlights.setup()
end

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

function M.get_next_user_status(current_status)
	return utils.get_next_user_status(current_status)
end

function M.get_next_status(current_status)
	return utils.get_next_status(current_status)
end

function M.get_full_cycle_order()
	return utils.get_full_cycle_order()
end

function M.get_icon(status)
	return utils.get_icon(status)
end

function M.get_color(status)
	return utils.get_color(status)
end

---------------------------------------------------------------------
-- 模块初始化
---------------------------------------------------------------------
function M.setup()
	M.setup_highlights()
	return M
end

return M
