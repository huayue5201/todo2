-- lua/todo2/module.lua
--- @module todo2.module
--- @brief 简化模块懒加载管理器

local M = {}

---------------------------------------------------------------------
-- 模块组定义（动态生成模块路径）
---------------------------------------------------------------------

-- 定义模块组，避免重复前缀
local module_groups = {
	-- 核心模块
	core = {
		"parser",
		"stats",
		"events",
		"autosave",
		"utils",
		"status", -- 添加状态模块
		"state_manager",
	},

	-- 存储模块
	store = {
		"nvim_store",
		"context",
		"meta",
		"index",
		"link",
		"cleanup",
		"types",
	},

	-- 链接模块
	link = {
		"creator",
		"jumper",
		"renderer",
		"syncer",
		"preview",
		"cleaner",
		"searcher",
		"viewer",
		"utils",
		"child",
		"service",
	},

	-- UI模块
	ui = {
		"window",
		"operations",
		"conceal",
		"file_manager",
		"statistics",
		"keymaps",
		"constants",
		"render",
	},
}

-- 基础模块（非分组模块）
local base_modules = {
	-- 主模块
	main = "todo2",

	-- 独立模块
	manager = "todo2.manager",
	keymaps = "todo2.keymaps",
	config = "todo2.config",
	module = "todo2.module",
}

---------------------------------------------------------------------
-- 动态构建模块表
---------------------------------------------------------------------

M.modules = {}

-- 添加基础模块
for name, path in pairs(base_modules) do
	M.modules[name] = path
end

-- 添加分组模块
for group, submodules in pairs(module_groups) do
	-- 添加主模块（如 "todo2.core"）
	M.modules[group] = "todo2." .. group

	-- 添加子模块（如 "todo2.core.parser"）
	for _, submodule in ipairs(submodules) do
		local key = group .. "." .. submodule
		local path = "todo2." .. group .. "." .. submodule
		M.modules[key] = path
	end
end

---------------------------------------------------------------------
-- 核心函数
---------------------------------------------------------------------

--- 获取模块（懒加载）
function M.get(name)
	local path = M.modules[name]

	if not path then
		-- 尝试直接加载（支持未预定义的模块）
		local success, module = pcall(require, name)
		if success then
			return module
		end

		-- 尝试加上 todo2. 前缀
		success, module = pcall(require, "todo2." .. name)
		if success then
			-- 自动注册新发现的模块
			M.modules[name] = "todo2." .. name
			return module
		end

		-- 尝试在模块组中查找
		for group, _ in pairs(module_groups) do
			if name:match("^" .. group .. "%.") then
				-- 这是一个未定义的子模块，自动生成路径
				local new_path = "todo2." .. name
				success, module = pcall(require, new_path)
				if success then
					M.modules[name] = new_path
					return module
				end
			end
		end

		error(string.format("模块不存在: %s", name))
	end

	return require(path)
end

--- 检查模块是否已加载
function M.is_loaded(name)
	local path = M.modules[name]
	return path and package.loaded[path] ~= nil
end

--- 重新加载模块（热重载）
function M.reload(name)
	local path = M.modules[name]
	if path then
		package.loaded[path] = nil
		return require(path)
	end
	return nil
end

--- 重新加载所有模块
function M.reload_all()
	for name, path in pairs(M.modules) do
		package.loaded[path] = nil
	end
	print("✅ 所有模块已重新加载")
end

--- 获取所有已加载的模块
function M.get_loaded_modules()
	local loaded = {}
	for name, path in pairs(M.modules) do
		if package.loaded[path] then
			loaded[name] = path
		end
	end
	return loaded
end

--- 添加新模块（运行时扩展）
function M.add_module(name, path)
	if M.modules[name] then
		vim.notify(string.format("模块已存在: %s (%s)", name, M.modules[name]), vim.log.levels.WARN)
		return false
	end

	M.modules[name] = path
	return true
end

--- 打印模块状态（调试用）
function M.print_status()
	print("=== 模块状态 ===")
	print(string.format("总模块数: %d", #vim.tbl_keys(M.modules)))

	local loaded = M.get_loaded_modules()
	print(string.format("已加载: %d", #vim.tbl_keys(loaded)))
	print(string.format("未加载: %d", #vim.tbl_keys(M.modules) - #vim.tbl_keys(loaded)))

	if vim.g.todo2_debug then
		print("\n已加载模块:")
		for name, path in pairs(loaded) do
			print(string.format("  %-20s -> %s", name, path))
		end
	end
end

---------------------------------------------------------------------
-- 便捷访问方式
---------------------------------------------------------------------

setmetatable(M, {
	__index = function(self, key)
		-- 检查是否在模块表中
		if rawget(self, "modules")[key] then
			return self.get(key)
		end
		-- 否则返回原始值
		return rawget(self, key)
	end,

	__newindex = function(self, key, value)
		-- 防止意外修改
		if key == "modules" then
			error("不能直接修改 modules 表")
		end
		rawset(self, key, value)
	end,
})

return M
