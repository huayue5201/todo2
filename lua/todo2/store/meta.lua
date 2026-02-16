-- lua/todo2/store/meta.lua
-- 元数据管理模块（终极修复版：统一创建逻辑，防止计数覆盖）

local M = {}

local store = require("todo2.store.nvim_store")

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------

--- 确保元数据存在且包含必要字段
--- @param meta table|nil 现有的元数据
--- @return table 确保存在的元数据
local function ensure_meta_exists(meta)
	meta = meta or {}

	-- 如果未初始化，设置基础字段
	if not meta.initialized then
		meta.initialized = true
		meta.version = "2.0"
		meta.created_at = meta.created_at or os.time()
		meta.project_root = meta.project_root or vim.fn.getcwd()
		-- 重要：不重置计数，保留现有值
	end

	-- 确保所有计数字段存在
	meta.total_links = meta.total_links or 0
	meta.todo_links = meta.todo_links or 0
	meta.code_links = meta.code_links or 0
	meta.last_sync = meta.last_sync or os.time()

	return meta
end

--- 获取元数据（自动确保存在）
--- @return table
local function get_meta_safe()
	local meta = store.get_key("todo.meta") or {}
	return ensure_meta_exists(meta)
end

---------------------------------------------------------------------
-- 公共 API
---------------------------------------------------------------------

--- 初始化元数据
--- @param force_recount boolean|nil 是否强制重新计数（基于现有链接）
--- @return boolean
function M.init(force_recount)
	local meta = store.get_key("todo.meta") or {}

	if force_recount then
		-- 强制重新计数：基于现有链接重新计算
		local todo_prefix = "todo.links.todo."
		local code_prefix = "todo.links.code."

		local todo_ids = store.get_namespace_keys(todo_prefix:sub(1, -2)) or {}
		local code_ids = store.get_namespace_keys(code_prefix:sub(1, -2)) or {}

		local todo_count = 0
		local code_count = 0

		-- 只统计 active = true 的链接
		for _, id in ipairs(todo_ids) do
			local link = store.get_key(todo_prefix .. id)
			if link and link.active ~= false then
				todo_count = todo_count + 1
			end
		end

		for _, id in ipairs(code_ids) do
			local link = store.get_key(code_prefix .. id)
			if link and link.active ~= false then
				code_count = code_count + 1
			end
		end

		meta = {
			initialized = true,
			version = "2.0",
			created_at = meta.created_at or os.time(),
			last_sync = os.time(),
			total_links = todo_count + code_count,
			todo_links = todo_count,
			code_links = code_count,
			project_root = meta.project_root or vim.fn.getcwd(),
		}
	else
		-- 正常初始化：确保元数据存在但保留现有计数
		meta = ensure_meta_exists(meta)
	end

	store.set_key("todo.meta", meta)
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
	return get_meta_safe()
end

--- 更新元数据字段
--- @param updates table
function M.update(updates)
	local meta = get_meta_safe()
	for k, v in pairs(updates) do
		meta[k] = v
	end
	store.set_key("todo.meta", meta)
end

--- 增加链接计数
--- @param link_type string "todo" 或 "code"
function M.increment_links(link_type)
	local meta = get_meta_safe() -- 确保元数据存在且包含必要字段

	meta.total_links = meta.total_links + 1
	if link_type == "todo" then
		meta.todo_links = meta.todo_links + 1
	elseif link_type == "code" then
		meta.code_links = meta.code_links + 1
	end
	meta.last_sync = os.time()

	store.set_key("todo.meta", meta)
end

--- 减少链接计数
--- @param link_type string "todo" 或 "code"
function M.decrement_links(link_type)
	local meta = get_meta_safe() -- 确保元数据存在且包含必要字段

	meta.total_links = math.max(0, meta.total_links - 1)
	if link_type == "todo" then
		meta.todo_links = math.max(0, meta.todo_links - 1)
	elseif link_type == "code" then
		meta.code_links = math.max(0, meta.code_links - 1)
	end
	meta.last_sync = os.time()

	store.set_key("todo.meta", meta)
end

--- 获取统计信息
--- @return table
function M.get_stats()
	local meta = get_meta_safe()
	return {
		total_links = meta.total_links,
		todo_links = meta.todo_links,
		code_links = meta.code_links,
		created_at = meta.created_at,
		last_sync = meta.last_sync,
		project_root = meta.project_root,
		version = meta.version,
	}
end

--- 重置元数据（用于测试）
--- @return boolean
function M.reset()
	local meta = {
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
	return true
end

return M
