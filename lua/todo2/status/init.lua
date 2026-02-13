-- lua/todo2/status/init.lua
--- @module todo2.status
--- @brief 状态管理模块入口（只处理状态显示和UI交互）

local M = {}

---------------------------------------------------------------------
-- 子模块加载（修改这里）
---------------------------------------------------------------------
local utils = require("todo2.status.utils") -- ⭐ 新增：使用工具模块
local highlights = require("todo2.status.highlights")
local ui = require("todo2.status.ui") -- UI交互模块

---------------------------------------------------------------------
-- 配置API（转发到utils模块）
---------------------------------------------------------------------

--- 获取状态配置
--- @param status string 状态名称
--- @return table 配置表
function M.get_config(status)
	return utils.get(status)
end

--- 获取所有状态配置
--- @return table 所有配置
function M.get_all_configs()
	return utils.get_all()
end

--- 获取用户可切换的状态循环顺序
--- @return table 状态循环数组
function M.get_cycle_order()
	return utils.get_user_cycle_order()
end

--- 判断状态是否可手动切换
--- @param status string 状态名称
--- @return boolean
function M.is_user_switchable(status)
	return utils.is_user_switchable(status)
end

---------------------------------------------------------------------
-- 显示API（转发到utils模块）
---------------------------------------------------------------------

--- 获取状态完整显示文本
--- @param link table 链接对象
--- @return string 显示文本
function M.get_status_display(link)
	local status = link.status or "normal"
	return utils.get_full_display(link, status)
end

--- 获取时间显示文本
--- @param link table 链接对象
--- @return string 时间文本
function M.get_time_display(link)
	return utils.get_time_display(link)
end

--- 获取分离的显示组件
--- @param link table 链接对象
--- @return table 显示组件（icon, icon_highlight, time, time_highlight）
function M.get_display_components(link)
	local status = link.status or "normal"
	return utils.get_display_components(link, status)
end

---------------------------------------------------------------------
-- UI交互API（转发到ui模块）
---------------------------------------------------------------------

--- 循环切换状态
--- @return boolean 是否成功
function M.cycle_status()
	return ui.cycle_status()
end

--- 显示状态选择菜单
function M.show_status_menu()
	return ui.show_status_menu()
end

--- 判断当前行是否有状态标记
--- @return boolean
function M.has_status_mark()
	return ui.has_status_mark()
end

--- 获取当前任务状态
--- @return string|nil 状态名称
function M.get_current_status()
	return ui.get_current_status()
end

--- 获取当前任务状态配置
--- @return table|nil 配置表
function M.get_current_status_config()
	return ui.get_current_status_config()
end

---------------------------------------------------------------------
-- 高亮API（转发到highlights模块）
---------------------------------------------------------------------

--- 获取状态高亮组名
--- @param status string 状态名称
--- @return string 高亮组名
function M.get_highlight(status)
	return highlights.get_highlight(status)
end

--- 获取时间戳高亮组名
--- @return string 高亮组名
function M.get_time_highlight()
	return highlights.get_time_highlight()
end

--- 设置高亮组
function M.setup_highlights()
	return highlights.setup()
end

---------------------------------------------------------------------
-- 工具函数（新增）
---------------------------------------------------------------------

--- 获取下一个状态（用户循环）
--- @param current_status string 当前状态
--- @return string 下一个状态
function M.get_next_user_status(current_status)
	return utils.get_next_user_status(current_status)
end

--- 获取下一个状态（完整循环）
--- @param current_status string 当前状态
--- @return string 下一个状态
function M.get_next_status(current_status)
	return utils.get_next_status(current_status)
end

--- 获取完整循环顺序
--- @return table 状态循环数组
function M.get_full_cycle_order()
	return utils.get_full_cycle_order()
end

--- 获取状态图标
--- @param status string 状态名称
--- @return string 图标
function M.get_icon(status)
	return utils.get_icon(status)
end

--- 获取状态颜色
--- @param status string 状态名称
--- @return string 颜色代码
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
