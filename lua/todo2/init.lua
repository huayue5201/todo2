-- lua/todo2/init.lua
--- @brief 主入口模块

local M = {}

-- setup 是否已执行（供惰性入口 plugin/todo2.lua 判断）
M._setup_done = false

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local config = require("todo2.config")
local dependencies = require("todo2.dependencies")
local autocmds = require("todo2.autocmds")
local highlights = require("todo2.render.highlights")

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
	-- 2. 初始化高亮系统
	-----------------------------------------------------------------
	M.setup_highlights()

	-----------------------------------------------------------------
	-- 3. 设置自动命令
	-----------------------------------------------------------------
	M.setup_autocmds()

	M._setup_done = true
end

--- 是否已完成初始化（惰性入口据此避免重复 setup）
function M.is_setup()
	return M._setup_done
end

---------------------------------------------------------------------
-- 高亮系统初始化
---------------------------------------------------------------------
function M.setup_highlights()
	if highlights and highlights.setup then
		local ok, err = pcall(function()
			local tags = config.get("tags")
			highlights.setup({ tags = tags })
		end)

		if not ok then
			vim.notify("高亮系统初始化失败: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

---------------------------------------------------------------------
-- 依赖检查与初始化
---------------------------------------------------------------------
function M.check_and_init_dependencies()
	return dependencies.check_and_init()
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
-- 重新加载高亮
---------------------------------------------------------------------
function M.reload_highlights()
	if highlights and highlights.clear then
		highlights.clear()
	end

	if highlights and highlights.setup then
		local tags = config.get("tags")
		highlights.setup({ tags = tags })
		return true
	end

	return false
end

return M
