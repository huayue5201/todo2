-- lua/todo2/store/init.lua
-- 存储模块入口

local M = {}

-- 核心模块
M.nvim_store = require("todo2.store.nvim_store")
M.config = require("todo2.config")

---------------------------------------------------------------------
-- 设置
---------------------------------------------------------------------
function M.setup(user_config)
	if user_config and type(user_config) == "table" then
		pcall(function()
			M.config.update(user_config)
		end)
	end

	return true
end

function M.init(user_config)
	return M.setup(user_config)
end

return M
