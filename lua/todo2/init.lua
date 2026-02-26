-- lua/todo2/init.lua
--- @module todo2
--- @brief 主入口模块，使用统一的模块懒加载系统

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local config = require("todo2.config")
local commands = require("todo2.commands")
local dependencies = require("todo2.dependencies")

-- 核心模块（将在 setup_modules 中初始化时按需加载）
local core = require("todo2.core")
local status = require("todo2.status")
local keymaps = require("todo2.keymaps")
local store = require("todo2.store")
local ui = require("todo2.ui")
local link = require("todo2.task")
local autocmds = require("todo2.autocmds")

---------------------------------------------------------------------
-- 插件初始化
---------------------------------------------------------------------
function M.setup(user_config)
	-- 初始化配置模块
	config.setup(user_config)

	-----------------------------------------------------------------
	-- 1. 检查并初始化依赖
	-----------------------------------------------------------------
	local deps_ok, deps_error = M.check_and_init_dependencies()
	if not deps_ok then
		vim.notify("依赖初始化失败: " .. deps_error, vim.log.levels.ERROR)
		return
	end

	-----------------------------------------------------------------
	-- 2. 初始化各个功能模块（每个模块负责自己的全部初始化）
	-----------------------------------------------------------------
	M.setup_modules()

	-----------------------------------------------------------------
	-- 3. 设置自动命令
	-----------------------------------------------------------------
	M.setup_autocmds()

	-- 设置归档功能
	commands.setup()
end

---------------------------------------------------------------------
-- 依赖检查与初始化
---------------------------------------------------------------------
function M.check_and_init_dependencies()
	-- 通过依赖模块处理
	return dependencies.check_and_init()
end

---------------------------------------------------------------------
-- 模块初始化
---------------------------------------------------------------------
function M.setup_modules()
	-- 按照依赖顺序初始化模块
	local init_order = {
		"core", -- 核心功能（基础）
		"status", -- 状态管理
		"keymaps", -- 按键映射系统
		"store", -- 数据存储
		"ui", -- 用户界面
		"link", -- 双向链接（依赖其他模块）
	}

	for _, module_name in ipairs(init_order) do
		local mod = nil
		if module_name == "core" then
			mod = core
		elseif module_name == "status" then
			mod = status
		elseif module_name == "keymaps" then
			mod = keymaps
		elseif module_name == "store" then
			mod = store
		elseif module_name == "ui" then
			mod = ui
		elseif module_name == "link" then
			mod = link
		end

		if mod then
			-- ⭐ 统一处理所有模块的初始化
			if mod.setup then
				local ok, err = pcall(mod.setup)
				if not ok then
					vim.notify(string.format("模块 %s 初始化失败: %s", module_name, err), vim.log.levels.ERROR)
				end
			elseif mod.init then
				local ok, err = pcall(mod.init)
				if not ok then
					vim.notify(string.format("模块 %s 初始化失败: %s", module_name, err), vim.log.levels.ERROR)
				end
			end
		end
	end
end

---------------------------------------------------------------------
-- 自动命令设置
---------------------------------------------------------------------
function M.setup_autocmds()
	if autocmds and autocmds.setup then
		autocmds.setup()
	end
end

---------------------------------------------------------------------
-- 配置相关函数
---------------------------------------------------------------------
function M.get_config()
	return config.get()
end

function M.get_config_value(key)
	return config.get(key)
end

function M.update_config(key_or_table, value)
	return config.update(key_or_table, value)
end

---------------------------------------------------------------------
-- 工具函数：检查依赖（公开接口）
---------------------------------------------------------------------
function M.check_dependencies()
	return dependencies.check()
end

---------------------------------------------------------------------
-- 返回主模块
---------------------------------------------------------------------
return M
