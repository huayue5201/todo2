-- lua/todo2/module.lua
--- @module todo2.module
--- @brief 简化模块懒加载管理器

local M = {}

---------------------------------------------------------------------
-- 模块缓存表
---------------------------------------------------------------------
M._cache = {}
M._loaded = {}

---------------------------------------------------------------------
-- 核心模块定义（必须预定义的模块）
---------------------------------------------------------------------
local core_modules = {
	-- 主入口模块
	main = "todo2",
	config = "todo2.config",
	module = "todo2.module",
	cache = "todo2.cache",
	dependencies = "todo2.dependencies",
	autocmds = "todo2.autocmds",

	-- 核心功能模块
	core = "todo2.core",
	store = "todo2.store",
	link = "todo2.link",
	ui = "todo2.ui",
	keymaps = "todo2.keymaps",
	status = "todo2.status", -- 添加状态模块
}

---------------------------------------------------------------------
-- 动态模块发现
---------------------------------------------------------------------

--- 尝试发现模块路径
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
function M.is_loaded(name)
	return M._loaded[name] ~= nil
end

--- 重新加载模块（热重载）
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
function M.get_loaded_modules()
	return vim.deepcopy(M._loaded)
end

--- 获取模块加载状态
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
-- 简便访问方式
---------------------------------------------------------------------

-- 为了保持简单，不设置元表魔术
-- 鼓励使用 M.get(name) 方式访问

return M
