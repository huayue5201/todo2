-- lua/todo2/store/init.lua
-- 存储模块主入口，统一导出所有功能

local M = {}

---------------------------------------------------------------------
-- 模块导出
---------------------------------------------------------------------

-- 基础模块
M.link = require("todo2.store.link")
M.index = require("todo2.store.index")
M.types = require("todo2.store.types")
M.meta = require("todo2.store.meta")

-- 清理功能
M.cleanup = require("todo2.store.cleanup")

-- 工具模块
M.locator = require("todo2.store.locator") -- 现在包含上下文定位功能
M.context = require("todo2.store.context")
M.consistency = require("todo2.store.consistency")
M.state_machine = require("todo2.store.state_machine")
M.autofix = require("todo2.store.autofix")
M.utils = require("todo2.store.utils")

-- 新增模块
M.trash = require("todo2.store.trash")
M.verification = require("todo2.store.verification")
M.conflict = require("todo2.store.conflict")
M.config = require("todo2.store.config")

-- 存储后端
M.nvim_store = require("todo2.store.nvim_store")

---------------------------------------------------------------------
-- ⭐ 核心：初始化配置并启动所有后台任务
---------------------------------------------------------------------
--- @param user_config table|nil 用户自定义配置
function M.setup(user_config)
	-- 1. 加载配置模块
	if type(M.config) ~= "table" or M.config.get == nil then
		M.config = require("todo2.store.config")
	end

	-- 2. 加载默认配置
	local success, err = pcall(function()
		M.config.load()
	end)
	if not success then
		vim.notify("加载配置失败: " .. tostring(err), vim.log.levels.WARN)
	end

	-- 3. 合并用户配置
	if user_config and type(user_config) == "table" then
		pcall(function()
			M.config.update(user_config)
		end)
	end

	-- 4. 初始化元数据
	pcall(function()
		M.meta.init()
	end)

	-- 5. 启动自动验证（如果启用）
	if M.config.get("verification.enabled") then
		local interval = M.config.get("verification.auto_verify_interval")
		if interval and type(interval) == "number" then
			pcall(function()
				M.verification.setup_auto_verification(interval)
			end)
		end
	end

	-- 6. ⭐ 启动自动修复（位置修复 + 全量同步）
	local autofix_enabled = M.config.get("autofix.enabled")
	local sync_on_save = M.config.get("sync.on_save")
	if autofix_enabled or sync_on_save then
		pcall(function()
			M.autofix.setup_autofix()
		end)
	end

	-- 7. 启动自动修复（旧配置兼容，仅当autofix.enabled为true时）
	if M.config.get("autofix.enabled") and not sync_on_save then
		-- 确保至少启用位置修复
		-- 已在 autofix.setup_autofix 中处理
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

	-- 清除所有存储键
	local store = M.nvim_store.get()
	local all_keys = store:namespace_keys("todo")

	for _, key in ipairs(all_keys) do
		store:delete(key)
	end

	-- 重置配置
	M.config.reset()

	-- 重新初始化元数据
	M.meta.init()

	vim.notify("系统已重置", vim.log.levels.INFO)
	return true
end

return M
