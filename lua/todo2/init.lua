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
local keymaps = require("todo2.keymaps")
local autocmds = require("todo2.autocmds")
local highlights = require("todo2.render.highlights")

---------------------------------------------------------------------
-- 插件初始化
---------------------------------------------------------------------
function M.setup(user_config)
	-- 依赖 vim.async（Neovim 0.13+）
	if not vim.async then
		vim.notify("todo2 requires Neovim 0.13+ (depends on vim.async)", vim.log.levels.ERROR)
		return
	end

	-- 初始化配置模块
	config.setup(user_config)

	-----------------------------------------------------------------
	-- 1. 检查并初始化依赖
	-----------------------------------------------------------------
	local deps_ok, deps_error = M.check_and_init_dependencies()
	if not deps_ok then
		vim.notify("Dependency init failed: " .. deps_error, vim.log.levels.ERROR)
		return
	end

	-----------------------------------------------------------------
	-- 1.5 Phase 3：旧「类型状态」(fix/refactor/AI) 一次性迁移为标签
	-----------------------------------------------------------------
	pcall(function()
		require("todo2.core.migrate").run_once()
	end)

	-----------------------------------------------------------------
	-- 2. 初始化高亮系统
	-----------------------------------------------------------------
	M.setup_highlights()

	-----------------------------------------------------------------
	-- 3. 设置 TODO 文件核心映射
	-----------------------------------------------------------------
	M.setup_keymaps()

	-----------------------------------------------------------------
	-- 4. 设置自动命令
	-----------------------------------------------------------------
	M.setup_autocmds()

	-- 发布本实例的 RPC 地址，供 MCP 桥（mcp/todo2-mcp.lua）连接
	pcall(function()
		require("todo2.mcp").publish()
	end)

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
			highlights.setup()
		end)

		if not ok then
			vim.notify("Highlight system init failed: " .. tostring(err), vim.log.levels.ERROR)
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
-- TODO 文件核心映射
---------------------------------------------------------------------
function M.setup_keymaps()
	if keymaps and keymaps.setup then
		keymaps.setup()
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

return M
