-- lua/todo2/store/init.lua
-- 纯功能平移：只更新引用的模块

local M = {}

-- 核心模块
M.link = require("todo2.store.link")
M.meta = require("todo2.store.meta")
M.nvim_store = require("todo2.store.nvim_store")
M.config = require("todo2.config")

-- 懒加载模块
local function lazy_load(name)
	return setmetatable({}, {
		__index = function(_, k)
			local mod = require("todo2.store." .. name)
			M[name] = mod
			return mod[k]
		end,
		__call = function(_, ...)
			local mod = require("todo2.store." .. name)
			M[name] = mod
			return mod(...)
		end,
	})
end

M.verification = lazy_load("verification")
M.autofix = lazy_load("autofix")
M.consistency = lazy_load("consistency")

---------------------------------------------------------------------
-- 设置
---------------------------------------------------------------------
function M.setup(user_config)
	if user_config and type(user_config) == "table" then
		pcall(function()
			M.config.update(user_config)
		end)
	end

	pcall(function()
		M.meta.init()
	end)

	return true
end

function M.init(user_config)
	return M.setup(user_config)
end

return M
