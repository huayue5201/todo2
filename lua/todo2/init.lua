-- lua/todo2/init.lua
--- @brief 主入口模块（适配极简 keymap 系统）

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local config = require("todo2.config")
local commands = require("todo2.commands")
local dependencies = require("todo2.dependencies")
local core = require("todo2.core")
local status = require("todo2.status")
local keymaps = require("todo2.keymaps") -- ⭐ 新的极简 keymap 系统
local store = require("todo2.store")
local ui = require("todo2.ui")
local link = require("todo2.task")
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
	-- 3. 加载事件处理器
	-----------------------------------------------------------------
	pcall(require, "todo2.store.link.handler")

	-----------------------------------------------------------------
	-- 4. 初始化各个功能模块
	-----------------------------------------------------------------
	M.setup_modules()

	-----------------------------------------------------------------
	-- 5. 设置自动命令
	-----------------------------------------------------------------
	M.setup_autocmds()

	-- 设置归档功能
	commands.setup()
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
-- 模块初始化（适配极简 keymap 系统）
---------------------------------------------------------------------
function M.setup_modules()
	local init_order = {
		"core",
		"status",
		"keymaps", -- ⭐ 新 keymap 系统
		"store",
		"ui",
		"link",
	}

	for _, module_name in ipairs(init_order) do
		local mod = ({
			core = core,
			status = status,
			keymaps = keymaps,
			store = store,
			ui = ui,
			link = link,
		})[module_name]

		if mod then
			if mod.setup then
				local ok, err = pcall(mod.setup)
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
