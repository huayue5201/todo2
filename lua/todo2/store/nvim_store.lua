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

--- 递归清理表中的混合键，确保表可以被 JSON 序列化
--- 将所有整数键转换为字符串，避免混合键表
--- @param t any
--- @return any
local function sanitize_for_json(t, path)
	path = path or {}

	-- 处理非表类型
	if type(t) ~= "table" then
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
	for k, v in pairs(t) do
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

	-- 如果同时有整数和字符串键，记录警告（但只记录一次）
	if has_integer_key and has_string_key and #path <= 3 then
		vim.schedule(function()
			vim.notify(
				string.format("检测到混合键表，已自动转换为纯字符串键 (路径深度: %d)", #path),
				vim.log.levels.WARN
			)
		end)
	end

	-- 移除路径
	table.remove(path)

	return result
end

--- 获取存储实例（懒加载，带数据清洗包装）
--- @return NvimStore
function M.get()
	if not nvim_store then
		local raw_store = require("nvim-store3").project({
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

		-- ⭐ 包装 set 方法，自动清洗数据
		local original_set = raw_store.set
		raw_store.set = function(self, key, value)
			-- 清洗数据，确保可序列化
			local sanitized = sanitize_for_json(value)
			return original_set(self, key, sanitized)
		end

		-- ⭐ 可选：也包装 set_key 方法（如果存在）
		if raw_store.set_key then
			local original_set_key = raw_store.set_key
			raw_store.set_key = function(self, key, value)
				local sanitized = sanitize_for_json(value)
				return original_set_key(self, key, sanitized)
			end
		end

		nvim_store = raw_store
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

--- ⭐ 诊断函数：检查存储中所有数据
function M.diagnose()
	local store = M.get()
	local all_keys = store:namespace_keys("todo") or {}

	local stats = {
		total_keys = #all_keys,
		problematic_keys = {},
		healthy_keys = 0,
	}

	for _, key in ipairs(all_keys) do
		local ok, val = pcall(store.get, store, key)
		if not ok then
			table.insert(stats.problematic_keys, {
				key = key,
				error = tostring(val),
				type = "read_error",
			})
		else
			-- 检查是否存在混合键
			local function check_mixed_keys(t, checked)
				if type(t) ~= "table" then
					return false
				end
				if checked[t] then
					return false
				end
				checked[t] = true

				local has_int = false
				local has_str = false
				local mixed = false

				for k, v in pairs(t) do
					if type(k) == "number" then
						has_int = true
					elseif type(k) == "string" then
						has_str = true
					end

					if has_int and has_str then
						mixed = true
					end

					if check_mixed_keys(v, checked) then
						mixed = true
					end

					if mixed then
						break
					end
				end

				return mixed
			end

			local checked = {}
			if check_mixed_keys(val, checked) then
				table.insert(stats.problematic_keys, {
					key = key,
					type = "mixed_keys",
				})
			else
				stats.healthy_keys = stats.healthy_keys + 1
			end
		end
	end

	return stats
end

return M
