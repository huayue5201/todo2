-- lua/todo2/module.lua
--- @module todo2.module
--- @brief 简化模块懒加载管理器

--- @alias Todo2ModuleName
--- | '"main"'
--- | '"config"'
--- | '"cache"'
--- | '"dependencies"'
--- | '"autocmds"'
--- | '"commands"'
--- | '"core"'
--- | '"store"'
--- | '"link"'
--- | '"ui"'
--- | '"keymaps"'
--- | '"status"'
--- | string -- 支持动态模块名

--- @class Todo2ModuleManager
--- @field _cache table<string, string> 模块名 -> 模块路径缓存
--- @field _loaded table<string, any> 已加载模块缓存
--- @field get fun(name: Todo2ModuleName): any 获取模块
--- @field is_loaded fun(name: string): boolean 检查是否已加载
--- @field reload fun(name: Todo2ModuleName): any 重新加载模块
--- @field reload_all fun(): boolean 重新加载所有模块
--- @field get_loaded_modules fun(): table<string, any> 获取所有已加载模块
--- @field get_status fun(): {total_core: integer, loaded: integer, cache_size: integer} 获取状态
--- @field print_status fun(): nil 打印状态

--- @type Todo2ModuleManager
local M = {}

---------------------------------------------------------------------
-- 模块缓存表
---------------------------------------------------------------------
M._cache = {}
M._loaded = {}

---------------------------------------------------------------------
-- 核心模块定义（必须预定义的模块）
---------------------------------------------------------------------
--- @class CoreModules
--- @field main '"todo2"'
--- @field config '"todo2.config"'
--- @field cache '"todo2.cache"'
--- @field dependencies '"todo2.dependencies"'
--- @field autocmds '"todo2.autocmds"'
--- @field commands '"todo2.commands"'
--- @field core '"todo2.core"'
--- @field store '"todo2.store"'
--- @field link '"todo2.link"'
--- @field ui '"todo2.ui"'
--- @field keymaps '"todo2.keymaps"'
--- @field status '"todo2.status"'

--- @type table<string, string>
local core_modules = {
	-- 主入口模块
	main = "todo2",
	config = "todo2.config",
	module = "todo2.module",
	cache = "todo2.cache",
	dependencies = "todo2.dependencies",
	autocmds = "todo2.autocmds",
	commands = "todo2.commands",

	-- 核心功能模块
	core = "todo2.core",
	store = "todo2.store",
	link = "todo2.link",
	ui = "todo2.ui",
	keymaps = "todo2.keymaps",
	status = "todo2.status",
}

---------------------------------------------------------------------
-- 动态模块发现
---------------------------------------------------------------------

--- 尝试发现模块路径
--- @param name string 模块名称
--- @return string|nil 发现的模块路径
local function discover_module_path(name)
	-- 尝试直接加载（完整路径）
	local success, module = pcall(require, name)
	if success then
		return name
	end

	-- 尝试加上 todo2. 前缀
	local prefixed_name = "todo2." .. name
	success, module = pcall(require, prefixed_name)
	if success then
		return prefixed_name
	end

	-- 尝试解析二级模块（如 core.parser -> todo2.core.parser）
	if name:match("%.") then
		local parts = vim.split(name, "%.")
		if #parts == 2 then
			local group, submodule = parts[1], parts[2]
			local full_path = string.format("todo2.%s.%s", group, submodule)
			success, module = pcall(require, full_path)
			if success then
				return full_path
			end
		elseif #parts == 3 then
			-- 处理三级模块（如 core.state_manager -> todo2.core.state_manager）
			local full_path = "todo2." .. name
			success, module = pcall(require, full_path)
			if success then
				return full_path
			end
		end
	end

	return nil
end

---------------------------------------------------------------------
-- 核心函数
---------------------------------------------------------------------

--- 获取模块（懒加载 + 动态发现）
--- @param name Todo2ModuleName 模块名称
--- @return any 加载的模块
function M.get(name)
	-- 检查缓存
	if M._loaded[name] then
		return M._loaded[name]
	end

	-- 查找模块路径
	local path = core_modules[name]
	if not path then
		-- 动态发现模块路径
		path = discover_module_path(name)
		if not path then
			error(string.format("模块不存在: %s", name))
		end
	end

	-- 加载模块并缓存
	local module = require(path)
	M._loaded[name] = module
	M._cache[name] = path

	return module
end

--- 检查模块是否已加载
--- @param name string 模块名称
--- @return boolean 是否已加载
function M.is_loaded(name)
	return M._loaded[name] ~= nil
end

--- 重新加载模块（热重载）
--- @param name Todo2ModuleName 模块名称
--- @return any 重新加载后的模块
function M.reload(name)
	local path = M._cache[name] or core_modules[name]
	if path then
		package.loaded[path] = nil
		M._loaded[name] = nil
		return M.get(name)
	end

	-- 尝试重新发现
	M._loaded[name] = nil
	M._cache[name] = nil
	return M.get(name)
end

--- 重新加载所有模块
--- @return boolean 是否成功
function M.reload_all()
	-- 清除所有模块缓存
	M._loaded = {}
	M._cache = {}

	-- 重新加载核心模块
	for name, path in pairs(core_modules) do
		if package.loaded[path] then
			package.loaded[path] = nil
		end
	end

	-- 重新加载已发现模块
	for name, path in pairs(M._cache) do
		if package.loaded[path] then
			package.loaded[path] = nil
		end
	end

	print("✅ 所有模块已重新加载")
	return true
end

--- 获取所有已加载的模块
--- @return table<string, any> 已加载模块表
function M.get_loaded_modules()
	return vim.deepcopy(M._loaded)
end

--- 获取模块加载状态
--- @return {total_core: integer, loaded: integer, cache_size: integer} 状态信息
function M.get_status()
	local loaded_count = 0
	for _ in pairs(M._loaded) do
		loaded_count = loaded_count + 1
	end

	return {
		total_core = #vim.tbl_keys(core_modules),
		loaded = loaded_count,
		cache_size = #vim.tbl_keys(M._cache),
	}
end

--- 打印模块状态（调试用）
function M.print_status()
	local status = M.get_status()

	print("=== 模块状态 ===")
	print(string.format("核心模块: %d", status.total_core))
	print(string.format("已加载: %d", status.loaded))
	print(string.format("缓存: %d", status.cache_size))

	if vim.g.todo2_debug then
		print("\n已加载模块:")
		for name, module in pairs(M._loaded) do
			print(string.format("  %-20s", name))
		end

		print("\n模块路径缓存:")
		for name, path in pairs(M._cache) do
			print(string.format("  %-20s -> %s", name, path))
		end
	end
end

---------------------------------------------------------------------
-- 简便访问方式（可选，增强LSP支持）
---------------------------------------------------------------------

-- 为常用模块提供快捷方式，这样LSP可以直接跳转
-- 例如：local config = M.get_config()

--- @return todo2.config
function M.get_config()
	return M.get("config")
end

--- @return todo2.ui
function M.get_ui()
	return M.get("ui")
end

--- @return todo2.store
function M.get_store()
	return M.get("store")
end

--- @return todo2.core
function M.get_core()
	return M.get("core")
end

--- @return todo2.keymaps
function M.get_keymaps()
	return M.get("keymaps")
end

--- @return todo2.status
function M.get_status_module()
	return M.get("status")
end

return M
