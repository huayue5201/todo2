-- lua/todo2/init.lua
--- @module todo2
--- @brief 主入口模块，使用统一的模块懒加载系统

local M = {}

---------------------------------------------------------------------
-- 统一的模块加载器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 统一的配置管理
---------------------------------------------------------------------
local config_module = require("todo2.config")

---------------------------------------------------------------------
-- 插件初始化
---------------------------------------------------------------------
function M.setup(user_config)
	-- 初始化配置模块
	config_module.setup(user_config)

	-- 验证配置
	local valid, errors = config_module.validate()
	if not valid then
		for _, err in ipairs(errors) do
			vim.notify("配置错误: " .. err, vim.log.levels.ERROR)
		end
		return
	end

	-- 获取配置
	local config = config_module.get()

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

	vim.notify("todo2 插件初始化完成", vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- 依赖检查与初始化
---------------------------------------------------------------------
function M.check_and_init_dependencies()
	-- 通过依赖模块处理
	local dependencies = module.get("dependencies")
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
		"store", -- 数据存储
		"ui", -- 用户界面
		"link", -- 双向链接（依赖其他模块）
	}

	for _, module_name in ipairs(init_order) do
		local mod = module.get(module_name)
		if mod and mod.setup then
			mod.setup()
		elseif module_name == "store" and mod and mod.init then
			-- store 模块保持向后兼容
			local success = mod.init()
			if not success then
				vim.notify("存储模块初始化失败，部分功能可能不可用", vim.log.levels.ERROR)
			end
		end
	end
end

---------------------------------------------------------------------
-- 自动命令设置
---------------------------------------------------------------------
function M.setup_autocmds()
	local autocmds = module.get("autocmds")
	autocmds.setup()
end

---------------------------------------------------------------------
-- 配置相关函数（提供向后兼容的接口）
---------------------------------------------------------------------
function M.get_config()
	return config_module.get()
end

function M.get_link_config()
	return config_module.get_link()
end

function M.get_store_config()
	return config_module.get_store()
end

function M.get_ui_config()
	return config_module.get_ui()
end

function M.get_conceal_config()
	return config_module.get_conceal()
end

---------------------------------------------------------------------
-- 工具函数：重新加载所有模块
---------------------------------------------------------------------
function M.reload_all()
	module.reload_all()
end

---------------------------------------------------------------------
-- 工具函数：模块加载状态
---------------------------------------------------------------------
function M.get_module_status()
	return module.get_status()
end

---------------------------------------------------------------------
-- 工具函数：打印模块状态（调试用）
---------------------------------------------------------------------
function M.print_module_status()
	module.print_status()
end

---------------------------------------------------------------------
-- 工具函数：检查依赖（公开接口）
---------------------------------------------------------------------
function M.check_dependencies()
	local dependencies = module.get("dependencies")
	return dependencies.check()
end

---------------------------------------------------------------------
-- 返回主模块
---------------------------------------------------------------------
return M
