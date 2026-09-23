-- lua/todo2/task/init.lua
--- @brief 任务管理模块入口

local M = {}

local status = require("todo2.status")

function M.setup()
	-- 初始化状态模块的其他功能
	if status and status.setup then
		status.setup()
	end

	return M
end

return M
