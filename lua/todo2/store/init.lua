-- lua/todo2/store/init.lua
-- 存储模块主入口，统一导出所有功能

local M = {}

---------------------------------------------------------------------
-- 模块导出
---------------------------------------------------------------------

-- 基础模块（必须立即加载）
M.link = require("todo2.store.link")
M.meta = require("todo2.store.meta")
M.config = require("todo2.store.config")
M.nvim_store = require("todo2.store.nvim_store")

-- ⭐ 按需加载的非核心模块（延迟加载）
local function lazy_load(name)
	return setmetatable({}, {
		__index = function(_, k)
			local mod = require("todo2.store." .. name)
			M[name] = mod -- 缓存
			return mod[k]
		end,
		__call = function(_, ...)
			local mod = require("todo2.store." .. name)
			M[name] = mod
			return mod(...)
		end,
	})
end

-- 这些模块仅在 setup 中按需加载，无需预先 require
M.verification = lazy_load("verification")
M.autofix = lazy_load("autofix")

---------------------------------------------------------------------
-- ⭐ 核心：初始化配置并启动所有后台任务
---------------------------------------------------------------------
--- @param user_config table|nil 用户自定义配置
function M.setup(user_config)
	-- 1. 配置已加载，直接使用
	M.config.load()

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

	-- 5. 启动自动修复 + 全量同步
	local autofix_enabled = M.config.get("autofix.enabled")
	local sync_on_save = M.config.get("sync.on_save")
	if autofix_enabled or sync_on_save then
		pcall(function()
			M.autofix.setup_autofix()
		end)
	end

	return true
end

--- 获取配置
--- @param key string|nil 配置键，nil返回全部
--- @return any 配置值
function M.get_config(key)
	return M.config.get(key)
end

--- 设置配置
--- @param key string 配置键
--- @param value any 配置值
function M.set_config(key, value)
	return M.config.set(key, value)
end

--- 重置系统（清除所有数据，用于测试）
--- @param confirm boolean 确认标志，必须为true
--- @return boolean 是否成功
function M.reset_system(confirm)
	if not confirm then
		vim.notify("重置系统需要确认，请传递 confirm=true", vim.log.levels.ERROR)
		return false
	end

	vim.notify("正在重置系统...", vim.log.levels.WARN)

	local store = M.nvim_store.get()
	local all_keys = store:namespace_keys("todo")

	for _, key in ipairs(all_keys) do
		store:delete(key)
	end

	M.config.reset()
	M.meta.init()

	vim.notify("系统已重置", vim.log.levels.INFO)
	return true
end

return M
