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
-- 显示API（转发到utils模块）
---------------------------------------------------------------------

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

---------------------------------------------------------------------
-- 高亮API（转发到highlights模块）
---------------------------------------------------------------------

function M.setup_highlights()
	return highlights.setup()
end

---------------------------------------------------------------------
-- 模块初始化
---------------------------------------------------------------------
function M.setup()
	M.setup_highlights()
	return M
end

return M
