-- lua/todo2/store/nvim_store.lua
--- @module todo2.store.nvim_store

local M = {}

----------------------------------------------------------------------
-- 内部存储实例
----------------------------------------------------------------------
local nvim_store

--- @class NvimStore
--- @field get fun(self, key: string): any
--- @field set fun(self, key: string, value: any)
--- @field del fun(self, key: string)
--- @field namespace_keys fun(self, ns: string): string[]
--- @field on fun(self, event: string, cb: fun(ev: table))

--- 获取存储实例（懒加载）
--- @return NvimStore
function M.get()
	if not nvim_store then
		nvim_store = require("nvim-store3").project({
			auto_encode = true,
			storage = {
				backend = "json",
				flush_delay = 1000,
			},
			plugins = {
				basic_cache = {
					enabled = true,
					default_ttl = 300,
				},
			},
		})

		-- 事件监听
		nvim_store:on("set", function(ev)
			if ev.key:match("^todo%.links%.") then
				-- 可加调试日志
			end
		end)
	end
	return nvim_store
end

--- 重新初始化存储
function M.reinit()
	nvim_store = nil
	return M.get()
end

--- @param key string
--- @return any
function M.get_key(key)
	return M.get():get(key)
end

--- @param key string
--- @param value any
function M.set_key(key, value)
	return M.get():set(key, value)
end

--- @param key string
function M.delete_key(key)
	return M.get():delete(key)
end

--- @param namespace string
--- @return string[]
function M.get_namespace_keys(namespace)
	return M.get():namespace_keys(namespace)
end

return M
