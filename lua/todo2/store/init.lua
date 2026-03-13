-- lua/todo2/store/init.lua
-- 重写版：对齐新的 autofix / verification / cleanup / consistency / locator 体系

local M = {}

---------------------------------------------------------------------
-- 核心模块（立即加载）
---------------------------------------------------------------------
M.link = require("todo2.store.link")
M.meta = require("todo2.store.meta")
M.nvim_store = require("todo2.store.nvim_store")
M.config = require("todo2.config")

---------------------------------------------------------------------
-- 延迟加载模块（保持向后兼容）
---------------------------------------------------------------------
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
M.cleanup = lazy_load("cleanup")
M.consistency = lazy_load("consistency")

---------------------------------------------------------------------
-- 初始化入口
---------------------------------------------------------------------
function M.setup(user_config)
	-----------------------------------------------------------------
	-- 1. 合并用户配置
	-----------------------------------------------------------------
	if user_config and type(user_config) == "table" then
		pcall(function()
			M.config.update(user_config)
		end)
	end

	-----------------------------------------------------------------
	-- 2. 初始化元数据（统计）
	-----------------------------------------------------------------
	pcall(function()
		M.meta.init()
	end)

	-----------------------------------------------------------------
	-- 4. 自动修复（autofix）初始化
	-----------------------------------------------------------------
	local autofix_enabled = M.config.get("autofix.enabled")
	local on_save = M.config.get("autofix.on_save")

	if autofix_enabled or on_save then
		pcall(function()
			local autofix = require("todo2.store.autofix")
			autofix.setup_autofix()

			-- 配置防抖/节流
			local debounce_ms = M.config.get("autofix.debounce_ms")
			if debounce_ms then
				autofix.set_config({ DEBOUNCE_MS = debounce_ms })
			end

			local throttle_ms = M.config.get("autofix.throttle_ms")
			if throttle_ms then
				autofix.set_config({ THROTTLE_MS = throttle_ms })
			end

			local max_file_size_kb = M.config.get("autofix.max_file_size_kb")
			if max_file_size_kb then
				autofix.set_config({ MAX_FILE_SIZE_KB = max_file_size_kb })
			end
		end)
	end

	return true
end

---------------------------------------------------------------------
-- 向后兼容
---------------------------------------------------------------------
function M.init(user_config)
	return M.setup(user_config)
end

return M
