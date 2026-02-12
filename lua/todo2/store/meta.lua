-- lua/todo2/store/meta.lua

local M = {}

local store = require("todo2.store.nvim_store")

--- 初始化元数据
--- @return boolean
function M.init()
	local meta = store.get_key("todo.meta") or {}
	if not meta.initialized then
		meta = {
			initialized = true,
			version = "2.0",
			created_at = os.time(),
			last_sync = os.time(),
			total_links = 0,
			todo_links = 0,
			code_links = 0,
			project_root = vim.fn.getcwd(),
		}
		store.set_key("todo.meta", meta)
	else
		meta.todo_links = meta.todo_links or 0
		meta.code_links = meta.code_links or 0
		store.set_key("todo.meta", meta)
	end
	return true
end

--- 获取项目根目录
--- @return string
function M.get_project_root()
	local meta = store.get_key("todo.meta") or {}
	if meta.project_root and meta.project_root ~= "" then
		return meta.project_root
	end
	return vim.fn.getcwd()
end

--- 获取元数据
--- @return table
function M.get()
	return store.get_key("todo.meta") or {}
end

--- 更新元数据字段
--- @param updates table
function M.update(updates)
	local meta = M.get()
	for k, v in pairs(updates) do
		meta[k] = v
	end
	store.set_key("todo.meta", meta)
end

--- 增加链接计数
--- @param link_type string
function M.increment_links(link_type)
	local meta = M.get()
	meta.total_links = (meta.total_links or 0) + 1
	if link_type == "todo" then
		meta.todo_links = (meta.todo_links or 0) + 1
	elseif link_type == "code" then
		meta.code_links = (meta.code_links or 0) + 1
	end
	meta.last_sync = os.time()
	store.set_key("todo.meta", meta)
end

--- 减少链接计数
--- @param link_type string
function M.decrement_links(link_type)
	local meta = M.get()
	meta.total_links = math.max(0, (meta.total_links or 0) - 1)
	if link_type == "todo" then
		meta.todo_links = math.max(0, (meta.todo_links or 0) - 1)
	elseif link_type == "code" then
		meta.code_links = math.max(0, (meta.code_links or 0) - 1)
	end
	meta.last_sync = os.time()
	store.set_key("todo.meta", meta)
end

--- 获取统计信息
--- @return table
function M.get_stats()
	local meta = M.get()
	return {
		total_links = meta.total_links or 0,
		todo_links = meta.todo_links or 0,
		code_links = meta.code_links or 0,
		created_at = meta.created_at or 0,
		last_sync = meta.last_sync or 0,
		project_root = meta.project_root or "",
		version = meta.version or "unknown",
	}
end

return M
