-- lua/todo2/module.lua
--- @module todo2.module
--- @brief 简化模块懒加载管理器

local M = {}

---------------------------------------------------------------------
-- 模块定义
---------------------------------------------------------------------

M.modules = {
	-- 主模块
	main = "todo2",

	-- 核心模块
	core = "todo2.core",
	["core.parser"] = "todo2.core.parser",
	["core.stats"] = "todo2.core.stats",
	["core.sync"] = "todo2.core.sync",
	["core.toggle"] = "todo2.core.toggle",
	["core.events"] = "todo2.core.events",
	["core.autosave"] = "todo2.core.autosave",

	-- 存储模块
	store = "todo2.store",
	["store.nvim_store"] = "todo2.store.nvim_store",
	["store.context"] = "todo2.store.context",
	["store.meta"] = "todo2.store.meta",
	["store.index"] = "todo2.store.index",
	["store.link"] = "todo2.store.link",
	["store.cleanup"] = "todo2.store.cleanup",
	["store.types"] = "todo2.store.types",

	-- 链接模块
	link = "todo2.link",
	["link.creator"] = "todo2.link.creator",
	["link.jumper"] = "todo2.link.jumper",
	["link.renderer"] = "todo2.link.renderer",
	["link.syncer"] = "todo2.link.syncer",
	["link.preview"] = "todo2.link.preview",
	["link.cleaner"] = "todo2.link.cleaner",
	["link.searcher"] = "todo2.link.searcher",
	["link.viewer"] = "todo2.link.viewer",
	["link.utils"] = "todo2.link.utils",
	["link.child"] = "todo2.link.child",

	-- UI模块
	ui = "todo2.ui",
	["ui.window"] = "todo2.ui.window",
	["ui.operations"] = "todo2.ui.operations",
	["ui.conceal"] = "todo2.ui.conceal",
	["ui.file_manager"] = "todo2.ui.file_manager",
	["ui.statistics"] = "todo2.ui.statistics",
	["ui.keymaps"] = "todo2.ui.keymaps",
	["ui.constants"] = "todo2.ui.constants",
	["ui.render"] = "todo2.ui.render",

	-- 其他模块
	manager = "todo2.manager",
	keymaps = "todo2.keymaps",
}

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

		error(string.format("模块不存在: %s (尝试路径: %s, todo2.%s)", name, name, name))
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
