-- lua/todo2/store/init.lua
--- @module todo2.store

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

----------------------------------------------------------------------
-- 兼容旧API的包装函数
----------------------------------------------------------------------

-- 路径规范化（保持与旧API兼容）
function M._normalize_path(path)
	local index = module.get("store.index")
	return index._normalize_path(path)
end

-- 上下文函数（保持与旧API兼容）
function M.build_context(prev, curr, next)
	local context = module.get("store.context")
	return context.build(prev, curr, next)
end

function M.context_match(old_ctx, new_ctx)
	local context = module.get("store.context")
	return context.match(old_ctx, new_ctx)
end

-- 初始化（保持与旧API兼容）
function M.init()
	local meta = module.get("store.meta")
	return meta.init()
end

-- 链接操作（保持与旧API兼容）
function M.add_todo_link(id, data)
	local link = module.get("store.link")
	return link.add_todo(id, data)
end

function M.add_code_link(id, data)
	local link = module.get("store.link")
	return link.add_code(id, data)
end

function M.get_todo_link(id, opts)
	local link = module.get("store.link")
	return link.get_todo(id, opts)
end

function M.get_code_link(id, opts)
	local link = module.get("store.link")
	return link.get_code(id, opts)
end

function M.delete_todo_link(id)
	local link = module.get("store.link")
	return link.delete_todo(id)
end

function M.delete_code_link(id)
	local link = module.get("store.link")
	return link.delete_code(id)
end

function M.get_all_todo_links()
	local link = module.get("store.link")
	return link.get_all_todo()
end

function M.get_all_code_links()
	local link = module.get("store.link")
	return link.get_all_code()
end

-- 索引操作（保持与旧API兼容）
function M.find_todo_links_by_file(filepath)
	local index = module.get("store.index")
	return index.find_todo_links_by_file(filepath)
end

function M.find_code_links_by_file(filepath)
	local index = module.get("store.index")
	return index.find_code_links_by_file(filepath)
end

-- ⭐ 修复：修改函数名以避免与模块名冲突
function M.cleanup_expired(days)
	local cleanup = module.get("store.cleanup")
	return cleanup.cleanup(days)
end

function M.validate_all_links(opts)
	local cleanup = module.get("store.cleanup")
	return cleanup.validate_all(opts)
end

----------------------------------------------------------------------
-- 高级功能
----------------------------------------------------------------------

--- 获取存储统计
--- @return table
function M.get_stats()
	local link = module.get("store.link")
	local meta = module.get("store.meta")

	local link_stats = link.get_all_todo()
	local code_stats = link.get_all_code()
	local meta_stats = meta.get_stats()

	return {
		todo_links = #link_stats,
		code_links = #code_stats,
		total_links = meta_stats.total_links,
		last_sync = meta_stats.last_sync,
		project_root = meta_stats.project_root,
		version = meta_stats.version,
	}
end

--- 导出所有数据（用于备份）
--- @return table
function M.export()
	local meta = module.get("store.meta")
	local link = module.get("store.link")

	local data = {
		meta = meta.get(),
		todo_links = link.get_all_todo(),
		code_links = link.get_all_code(),
		export_time = os.time(),
		export_version = "1.0",
	}

	return data
end

--- 导入数据（从备份恢复）
--- @param data table
--- @param opts table|nil
function M.import(data, opts)
	opts = opts or {}
	local overwrite = opts.overwrite or false

	if data.export_version ~= "1.0" then
		error("不支持的导出版本: " .. (data.export_version or "unknown"))
	end

	local store = module.get("store.nvim_store")

	if overwrite then
		-- 清除现有数据
		local todo_keys = store:namespace_keys("todo.links.todo")
		local code_keys = store:namespace_keys("todo.links.code")

		for _, key in ipairs(todo_keys) do
			store:del(key)
		end

		for _, key in ipairs(code_keys) do
			store:del(key)
		end
	end

	-- 导入元数据
	if data.meta then
		store.set_key("todo.meta", data.meta)
	end

	-- 导入链接
	if data.todo_links then
		for id, link in pairs(data.todo_links) do
			store.set_key("todo.links.todo." .. id, link)
		end
	end

	if data.code_links then
		for id, link in pairs(data.code_links) do
			store.set_key("todo.links.code." .. id, link)
		end
	end

	return true
end

----------------------------------------------------------------------
-- 模块初始化
----------------------------------------------------------------------
function M.setup()
	-- 初始化元数据
	M.init()

	-- 预加载常用模块（通过 module.get 触发加载）
	module.get("store.nvim_store")
	module.get("store.meta")

	return M
end

return M
