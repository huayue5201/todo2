-- lua/todo2/store/init.lua (更新版)
-- 存储模块主入口，统一导出所有功能

local M = {}

---------------------------------------------------------------------
-- 模块导出
---------------------------------------------------------------------

-- 基础模块（必须立即加载）
M.link = require("todo2.store.link")
M.meta = require("todo2.store.meta")
M.nvim_store = require("todo2.store.nvim_store")
M.config = require("todo2.config")

-- ⭐ 按需加载的非核心模块（延迟加载）
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
M.trash = lazy_load("trash")

---------------------------------------------------------------------
-- ⭐ 核心：初始化配置并启动所有后台任务
---------------------------------------------------------------------
--- @param user_config table|nil 用户自定义配置
function M.setup(user_config)
	-- 2. 合并用户配置
	if user_config and type(user_config) == "table" then
		pcall(function()
			M.config.update(user_config)
		end)
	end

	-- 3. 初始化元数据
	pcall(function()
		M.meta.init()
	end)

	-- 4. 启动自动验证（如果启用）
	if M.config.get("verification.enabled") then
		local interval = M.config.get("verification.auto_verify_interval")
		if interval and type(interval) == "number" then
			pcall(function()
				M.verification.setup_auto_verification(interval)
			end)
		end
	end

	-- 5. ⭐ 启动自动修复 + 全量同步（关键修复）
	local autofix_enabled = M.config.get("autofix.enabled")
	local on_save = M.config.get("autofix.on_save")

	if autofix_enabled or on_save then
		pcall(function()
			local autofix = require("todo2.store.autofix")
			autofix.setup_autofix()

			-- 可选：调整防抖/节流配置
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

-- ⭐ 添加 init 函数以保持向后兼容
function M.init(user_config)
	return M.setup(user_config)
end

return M
