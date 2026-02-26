-- lua/todo2/store/link.lua (临时转发器)
-- 兼容层，后续可删除

local M = {}

-- 转发到新的模块结构
local link_module = require("todo2.store.link.init")

-- 设置元表，动态转发所有调用
setmetatable(M, {
	__index = function(_, key)
		return link_module[key]
	end,
	__newindex = function()
		error("Cannot modify read-only forwarder module")
	end,
})

return M
