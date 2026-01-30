--- File: /Users/lijia/todo2/lua/todo2/status/init.lua ---
-- lua/todo2/status/init.lua
--- @module todo2.status
--- @brief 状态管理模块入口

local M = {}

---------------------------------------------------------------------
-- 子模块加载
---------------------------------------------------------------------
local config = require("todo2.status.config")
local highlights = require("todo2.status.highlights")

---------------------------------------------------------------------
-- 公开API（转发到子模块）
---------------------------------------------------------------------

-- 配置相关
function M.get_config(status)
	return config.get(status)
end

function M.get_all_configs()
	return config.get_all()
end

-- 获取用户可切换的状态循环
function M.get_cycle_order()
	return config.get_user_cycle_order()
end

-- 用户手动切换状态时使用的函数
function M.get_next_status(current_status)
	return config.get_next_user_status(current_status)
end

-- 显示相关
function M.get_status_display(link)
	local status = link.status or "normal"
	return config.get_full_display(link, status)
end

function M.get_time_display(link)
	return config.get_time_display(link)
end

-- 高亮相关
function M.get_highlight(status)
	return highlights.get_highlight(status)
end

function M.setup_highlights()
	return highlights.setup()
end

-- 判断状态是否可手动切换
function M.is_user_switchable(status)
	return config.is_user_switchable(status)
end

---------------------------------------------------------------------
-- 模块初始化
---------------------------------------------------------------------
function M.setup()
	M.setup_highlights()
	require("todo2.status.keymap") -- 只加载精简的键映射
	return M
end

return M
