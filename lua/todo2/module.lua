-- lua/todo2/module.lua
--- @module todo2.module
--- @brief 统一模块懒加载管理器

local M = {}

---------------------------------------------------------------------
-- 模块定义（完整列表）
---------------------------------------------------------------------

M.modules = {
	-- ===== 主模块 =====
	["main"] = { path = "todo2", loaded = false, instance = nil },

	-- ===== 核心模块 =====
	["core"] = { path = "todo2.core", loaded = false, instance = nil },
	["core.parser"] = { path = "todo2.core.parser", loaded = false, instance = nil },
	["core.stats"] = { path = "todo2.core.stats", loaded = false, instance = nil },
	["core.sync"] = { path = "todo2.core.sync", loaded = false, instance = nil },
	["core.toggle"] = { path = "todo2.core.toggle", loaded = false, instance = nil },
	["core.events"] = { path = "todo2.core.events", loaded = false, instance = nil },
	["core.autosave"] = { path = "todo2.core.autosave", loaded = false, instance = nil },

	-- ===== 链接模块 =====
	["link"] = { path = "todo2.link", loaded = false, instance = nil },
	["link.creator"] = { path = "todo2.link.creator", loaded = false, instance = nil },
	["link.jumper"] = { path = "todo2.link.jumper", loaded = false, instance = nil },
	["link.renderer"] = { path = "todo2.link.renderer", loaded = false, instance = nil },
	["link.syncer"] = { path = "todo2.link.syncer", loaded = false, instance = nil },
	["link.preview"] = { path = "todo2.link.preview", loaded = false, instance = nil },
	["link.cleaner"] = { path = "todo2.link.cleaner", loaded = false, instance = nil },
	["link.searcher"] = { path = "todo2.link.searcher", loaded = false, instance = nil },
	["link.viewer"] = { path = "todo2.link.viewer", loaded = false, instance = nil },
	["link.utils"] = { path = "todo2.link.utils", loaded = false, instance = nil },

	-- ===== UI 模块 =====
	["ui"] = { path = "todo2.ui", loaded = false, instance = nil },
	["ui.window"] = { path = "todo2.ui.window", loaded = false, instance = nil },
	["ui.operations"] = { path = "todo2.ui.operations", loaded = false, instance = nil },
	["ui.conceal"] = { path = "todo2.ui.conceal", loaded = false, instance = nil },
	["ui.file_manager"] = { path = "todo2.ui.file_manager", loaded = false, instance = nil },
	["ui.statistics"] = { path = "todo2.ui.statistics", loaded = false, instance = nil },
	["ui.keymaps"] = { path = "todo2.ui.keymaps", loaded = false, instance = nil },
	["ui.constants"] = { path = "todo2.ui.constants", loaded = false, instance = nil },

	-- ===== 其他模块 =====
	["render"] = { path = "todo2.render", loaded = false, instance = nil },
	["store"] = { path = "todo2.store", loaded = false, instance = nil },
	["manager"] = { path = "todo2.manager", loaded = false, instance = nil },
	["keymaps"] = { path = "todo2.keymaps", loaded = false, instance = nil },
	["utf8"] = { path = "todo2.utf8", loaded = false, instance = nil },
	["child"] = { path = "todo2.child", loaded = false, instance = nil },
}

---------------------------------------------------------------------
-- 获取模块（核心函数）
---------------------------------------------------------------------

function M.get(name)
	local module_info = M.modules[name]

	if not module_info then
		-- 动态模块（未预定义的）
		local success, module = pcall(require, name)
		if success then
			return module
		end

		-- 尝试加上 todo2. 前缀
		success, module = pcall(require, "todo2." .. name)
		if success then
			-- 动态注册这个模块
			M.modules[name] = {
				path = "todo2." .. name,
				loaded = true,
				instance = module,
			}
			return module
		end

		error(string.format("模块不存在: %s (尝试路径: %s, todo2.%s)", name, name, name))
	end

	if not module_info.loaded then
		module_info.instance = require(module_info.path)
		module_info.loaded = true
	end

	return module_info.instance
end

---------------------------------------------------------------------
-- 直接加载别名（方便使用）
---------------------------------------------------------------------

-- 你可以使用 M.core 代替 M.get("core")
setmetatable(M, {
	__index = function(self, key)
		-- 优先检查是否在模块表中
		local module_info = rawget(self, "modules")[key]
		if module_info then
			return self.get(key)
		end

		-- 尝试直接获取
		return rawget(self, key)
	end,
})

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

-- 检查模块是否已加载
function M.is_loaded(name)
	local module_info = M.modules[name]
	return module_info and module_info.loaded
end

-- 重新加载模块（热重载）
function M.reload(name)
	local module_info = M.modules[name]
	if module_info then
		-- 清理 package.loaded
		package.loaded[module_info.path] = nil

		-- 重新加载
		module_info.loaded = false
		module_info.instance = nil

		return M.get(name)
	end
	return nil
end

-- 重新加载所有模块（完整热重载）
function M.reload_all()
	for name, _ in pairs(M.modules) do
		M.reload(name)
	end
	print("✅ 所有模块已重新加载")
end

-- 获取模块状态（调试用）
function M.get_status()
	local status = {}
	for name, info in pairs(M.modules) do
		status[name] = {
			loaded = info.loaded,
			path = info.path,
			has_instance = info.instance ~= nil,
		}
	end
	return status
end

-- 打印模块状态
function M.print_status()
	local status = M.get_status()
	print("📊 模块加载状态:")
	print("=" .. string.rep("=", 50))

	local loaded = 0
	local total = 0

	for name, info in pairs(status) do
		total = total + 1
		if info.loaded then
			loaded = loaded + 1
			print(string.format("✅ [已加载] %-25s -> %s", name, info.path))
		else
			print(string.format("⏳ [未加载] %-25s -> %s", name, info.path))
		end
	end

	print("=" .. string.rep("=", 50))
	print(string.format("总计: %d/%d 个模块已加载", loaded, total))
end

-- 预加载常用模块（加快首次使用）
function M.preload_essential()
	local essentials = {
		"core",
		"link",
		"store",
		"ui",
		"core.parser",
		"core.events",
		"link.utils",
	}

	for _, name in ipairs(essentials) do
		M.get(name)
	end
end

---------------------------------------------------------------------
-- 依赖关系检查
---------------------------------------------------------------------

M.dependencies = {
	-- 主模块依赖
	["main"] = { "core", "link", "ui", "store" },

	-- 核心模块依赖
	["core"] = { "core.parser", "core.stats", "core.sync", "core.toggle", "core.events", "core.autosave" },
	["core.sync"] = { "core.parser", "core.stats" },
	["core.toggle"] = { "core.parser", "core.stats", "core.sync" },
	["core.events"] = { "core.parser", "ui", "link.renderer" },

	-- 链接模块依赖
	["link"] = { "store", "link.utils", "link.creator", "link.jumper", "link.renderer", "link.syncer" },
	["link.creator"] = { "store", "link.utils", "ui", "core.events", "core.autosave" },
	["link.jumper"] = { "store", "link.utils", "ui", "link.syncer" },
	["link.renderer"] = { "store", "core.parser" },
	["link.syncer"] = { "store", "core.events" },

	-- UI模块依赖
	["ui"] = { "ui.window", "ui.operations", "ui.conceal", "ui.file_manager", "ui.statistics", "ui.keymaps" },
	["ui.window"] = { "ui.keymaps", "core.events" },
	["ui.operations"] = { "core", "core.autosave", "core.events" },

	-- 其他模块依赖
	["render"] = { "core.parser" },
	["manager"] = { "store", "core.autosave", "core.events" },
	["keymaps"] = { "store", "core", "core.autosave", "core.events" },
	["child"] = { "ui", "link", "core.autosave", "core.events" },
}

-- 检查循环依赖（简单版）
function M.check_circular()
	local visited = {}
	local recursion_stack = {}

	local function dfs(module_name)
		visited[module_name] = true
		recursion_stack[module_name] = true

		local deps = M.dependencies[module_name] or {}
		for _, dep in ipairs(deps) do
			if recursion_stack[dep] then
				error(string.format("发现循环依赖: %s -> %s", module_name, dep))
			end
			if not visited[dep] then
				dfs(dep)
			end
		end

		recursion_stack[module_name] = false
	end

	for module_name, _ in pairs(M.dependencies) do
		if not visited[module_name] then
			dfs(module_name)
		end
	end

	return true
end

---------------------------------------------------------------------
-- 初始化
---------------------------------------------------------------------

-- 自动检查依赖（开发模式）
if vim.g.todo2_debug then
	local ok, err = pcall(M.check_circular)
	if not ok then
		vim.notify("TODO2 模块循环依赖: " .. err, vim.log.levels.ERROR)
	end
end

return M
