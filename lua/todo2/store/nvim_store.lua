-- lua/todo2/store/nvim_store.lua
--- @module todo2.store.nvim_store
--- 默认存储名（主库）；归档库等命名 store 通过 name 复用同一套读写接口。

local M = {}

local async_util = require("todo2.utils.async")

----------------------------------------------------------------------
-- 内部存储实例
----------------------------------------------------------------------
---@type table<string, table> 命名实例缓存（name -> 包装后的 store）
local instances = {}

---当前活动 store 名（所有 store.get_key 等调用都作用于它）
local active_name = "default"

--- 递归清理表中的混合键，确保表可以被 JSON 序列化
--- 将所有整数键转换为字符串，避免混合键表
--- @param t any
--- @return any
local function sanitize_for_json(t, path)
	path = path or {}

	-- 处理非表类型
	if type(t) ~= "table" then
		-- ⭐ 剥离无法被 JSON 序列化的类型（如 treesitter 节点 userdata）。
		-- 否则整个存储的 json_encode 会失败，导致所有任务数据在重启后丢失。
		local ttype = type(t)
		if ttype == "userdata" or ttype == "function" or ttype == "thread" or ttype == "cdata" then
			return nil
		end
		return t
	end

	-- 检查是否是循环引用（简单检测）
	for _, p in ipairs(path) do
		if p == t then
			-- 检测到循环引用，返回一个标记
			return { __circular_ref = true }
		end
	end

	-- 将当前表加入路径
	table.insert(path, t)

	local result = {}
	local has_string_key = false
	local has_integer_key = false

	-- 第一遍：检查键类型
	for k, _ in pairs(t) do
		if type(k) == "number" then
			has_integer_key = true
		elseif type(k) == "string" then
			has_string_key = true
		end
	end

	-- 第二遍：转换数据
	for k, v in pairs(t) do
		-- 递归处理值
		local sanitized_v = sanitize_for_json(v, path)

		-- ⭐ 跳过不可序列化的值（例如 userdata 字段）
		if sanitized_v ~= nil then
			-- 处理键
			if type(k) == "number" then
				-- 如果有字符串键，或者数字键不是连续的正整数，转换为字符串
				if has_string_key or k < 1 or math.floor(k) ~= k then
					result[tostring(k)] = sanitized_v
				else
					-- 纯数字键且无字符串键，可以保留为数组
					-- 但需要确保键是连续的
					result[k] = sanitized_v
				end
			else
				-- 字符串键直接保留
				result[k] = sanitized_v
			end
		end
	end

	-- 如果同时有整数和字符串键，记录警告（但只记录一次）
	if has_integer_key and has_string_key and #path <= 3 then
		async_util.defer(function()
			vim.notify(
				string.format("Mixed key table detected; converted to plain string keys (path depth: %d)", #path),
				vim.log.levels.WARN
			)
		end)
	end

	-- 移除路径
	table.remove(path)

	return result
end

--- 构建一个命名 store 实例（带数据清洗包装）
--- @param name string
--- @return table
local function build_instance(name)
	local opts = {
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
	}
	if name and name ~= "" and name ~= "default" then
		opts.name = name
	end

	local raw_store = require("nvim-store3").project(opts)

	-- ⭐ 包装 set 方法，自动清洗数据
	local original_set = raw_store.set
	raw_store.set = function(self, key, value)
		local sanitized = sanitize_for_json(value)
		return original_set(self, key, sanitized)
	end

	if raw_store.set_key then
		local original_set_key = raw_store.set_key
		raw_store.set_key = function(self, key, value)
			local sanitized = sanitize_for_json(value)
			return original_set_key(self, key, sanitized)
		end
	end

	return raw_store
end

--- 获取指定命名 store（懒加载）
--- @param name string|nil 缺省 "default"
--- @return table
function M.get_named(name)
	name = (name == nil or name == "") and "default" or name
	if not instances[name] then
		instances[name] = build_instance(name)
	end
	return instances[name]
end

--- 获取当前活动 store（懒加载，带数据清洗包装）
--- @return table
function M.get()
	return M.get_named(active_name)
end

--- 切换活动 store（影响所有 get_key/set_key/...）
--- @param name string
function M.set_active(name)
	active_name = (name == nil or name == "") and "default" or name
end

--- 在指定 store 上临时执行 fn，结束后恢复原活动 store
--- @param name string
--- @param fn fun():any
--- @return any
function M.with_active(name, fn)
	local prev = active_name
	M.set_active(name)
	local ok, r1, r2, r3 = pcall(fn)
	M.set_active(prev)
	if not ok then
		error(r1)
	end
	return r1, r2, r3
end

--- 刷新指定 store 到磁盘
--- @param name string|nil 缺省当前活动 store
--- @return boolean
function M.flush(name)
	local store = M.get_named(name or active_name)
	if store and store.flush then
		return store:flush()
	end
	return false
end

--- 卸载命名 store（flush + 释放内存）
--- @param name string
--- @return boolean
function M.unload(name)
	name = (name == nil or name == "") and "default" or name
	instances[name] = nil
	return require("nvim-store3").unload({ name = name })
end

--- 命名 store 是否已加载
--- @param name string
--- @return boolean
function M.is_loaded(name)
	name = (name == nil or name == "") and "default" or name
	return instances[name] ~= nil
end

--- @param key string
--- @return any
function M.get_key(key)
	return M.get():get(key)
end

--- @param key string
--- @param value any
function M.set_key(key, value)
	local store = M.get()
	-- 已经通过包装自动清洗，直接调用
	return store:set(key, value)
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
