-- lua/todo2/store/meta.lua
-- 元数据管理模块（终极修复版：区分活跃和归档链接）

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

	if not meta.initialized then
		meta.initialized = true
		meta.version = "2.0"
		meta.created_at = meta.created_at or os.time()
		meta.project_root = meta.project_root or vim.fn.getcwd()
	end

	-- ⭐ 确保所有计数字段存在
	meta.total_links = meta.total_links or 0
	meta.todo_links = meta.todo_links or 0
	meta.code_links = meta.code_links or 0

	-- ⭐ 新增：区分活跃和非活跃链接
	meta.active_todo_links = meta.active_todo_links or 0
	meta.active_code_links = meta.active_code_links or 0
	meta.archived_todo_links = meta.archived_todo_links or 0
	meta.archived_code_links = meta.archived_code_links or 0

	meta.last_sync = meta.last_sync or os.time()

	return meta
end

--- 获取元数据（自动确保存在）
--- @return table
local function get_meta_safe()
	local meta = store.get_key("todo.meta") or {}
	return ensure_meta_exists(meta)
end

--- ⭐ 新增：判断链接是否活跃
--- @param link table 链接对象
--- @return boolean
local function is_link_active(link)
	if not link then
		return false
	end
	-- 物理删除的标记为非活跃
	if link.physical_deleted then
		return false
	end
	-- 归档状态但物理标记还在的，可能仍算活跃
	-- 这里可以根据业务规则调整
	return link.active ~= false
end

---------------------------------------------------------------------
-- 公共 API
---------------------------------------------------------------------

--- 初始化元数据
--- @param force_recount boolean|nil 是否强制重新计数
--- @return boolean
function M.init(force_recount)
	local meta = store.get_key("todo.meta") or {}

	if force_recount then
		-- ⭐ 重新计数：基于实际链接状态
		local todo_prefix = "todo.links.todo."
		local code_prefix = "todo.links.code."

		local todo_ids = store.get_namespace_keys(todo_prefix:sub(1, -2)) or {}
		local code_ids = store.get_namespace_keys(code_prefix:sub(1, -2)) or {}

		local todo_count = 0
		local code_count = 0
		local active_todo = 0
		local active_code = 0
		local archived_todo = 0
		local archived_code = 0

		for _, id in ipairs(todo_ids) do
			local link = store.get_key(todo_prefix .. id)
			if link then
				todo_count = todo_count + 1
				if is_link_active(link) then
					active_todo = active_todo + 1
				else
					archived_todo = archived_todo + 1
				end
			end
		end

		for _, id in ipairs(code_ids) do
			local link = store.get_key(code_prefix .. id)
			if link then
				code_count = code_count + 1
				if is_link_active(link) then
					active_code = active_code + 1
				else
					archived_code = archived_code + 1
				end
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
			active_todo_links = active_todo,
			active_code_links = active_code,
			archived_todo_links = archived_todo,
			archived_code_links = archived_code,
			project_root = meta.project_root or vim.fn.getcwd(),
		}
	else
		meta = ensure_meta_exists(meta)
	end

	store.set_key("todo.meta", meta)
	return true
end

--- ⭐ 修改：增加链接计数（区分活跃状态）
--- @param link_type string "todo" 或 "code"
--- @param is_active boolean 是否活跃
function M.increment_links(link_type, is_active)
	local meta = get_meta_safe()

	meta.total_links = meta.total_links + 1

	if link_type == "todo" then
		meta.todo_links = meta.todo_links + 1
		if is_active then
			meta.active_todo_links = meta.active_todo_links + 1
		else
			meta.archived_todo_links = meta.archived_todo_links + 1
		end
	elseif link_type == "code" then
		meta.code_links = meta.code_links + 1
		if is_active then
			meta.active_code_links = meta.active_code_links + 1
		else
			meta.archived_code_links = meta.archived_code_links + 1
		end
	end

	meta.last_sync = os.time()
	store.set_key("todo.meta", meta)
end

--- ⭐ 修改：减少链接计数（区分活跃状态）
--- @param link_type string "todo" 或 "code"
--- @param is_active boolean 是否活跃
function M.decrement_links(link_type, is_active)
	local meta = get_meta_safe()

	meta.total_links = math.max(0, meta.total_links - 1)

	if link_type == "todo" then
		meta.todo_links = math.max(0, meta.todo_links - 1)
		if is_active then
			meta.active_todo_links = math.max(0, meta.active_todo_links - 1)
		else
			meta.archived_todo_links = math.max(0, meta.archived_todo_links - 1)
		end
	elseif link_type == "code" then
		meta.code_links = math.max(0, meta.code_links - 1)
		if is_active then
			meta.active_code_links = math.max(0, meta.active_code_links - 1)
		else
			meta.archived_code_links = math.max(0, meta.archived_code_links - 1)
		end
	end

	meta.last_sync = os.time()
	store.set_key("todo.meta", meta)
end

--- ⭐ 新增：更新链接活跃状态
--- @param id string 链接ID
--- @param link_type string "todo" 或 "code"
--- @param new_active boolean 新的活跃状态
function M.update_link_active_status(id, link_type, new_active)
	local meta = get_meta_safe()

	local link_key = (link_type == "todo") and "todo.links.todo." .. id or "todo.links.code." .. id
	local link = store.get_key(link_key)

	if not link then
		return false
	end

	local old_active = is_link_active(link)
	if old_active == new_active then
		return true
	end

	-- 更新计数
	if link_type == "todo" then
		if new_active then
			meta.active_todo_links = meta.active_todo_links + 1
			meta.archived_todo_links = math.max(0, meta.archived_todo_links - 1)
		else
			meta.active_todo_links = math.max(0, meta.active_todo_links - 1)
			meta.archived_todo_links = meta.archived_todo_links + 1
		end
	else
		if new_active then
			meta.active_code_links = meta.active_code_links + 1
			meta.archived_code_links = math.max(0, meta.archived_code_links - 1)
		else
			meta.active_code_links = math.max(0, meta.active_code_links - 1)
			meta.archived_code_links = meta.archived_code_links + 1
		end
	end

	store.set_key("todo.meta", meta)
	return true
end

--- ⭐ 修改：获取统计信息（包含详细分类）
function M.get_stats()
	local meta = get_meta_safe()
	return {
		total_links = meta.total_links,
		todo_links = meta.todo_links,
		code_links = meta.code_links,
		active_todo_links = meta.active_todo_links,
		active_code_links = meta.active_code_links,
		archived_todo_links = meta.archived_todo_links,
		archived_code_links = meta.archived_code_links,
		created_at = meta.created_at,
		last_sync = meta.last_sync,
		project_root = meta.project_root,
		version = meta.version,
	}
end

--- ⭐ 新增：诊断计数不一致
function M.diagnose()
	local meta = get_meta_safe()

	local todo_prefix = "todo.links.todo."
	local code_prefix = "todo.links.code."

	local todo_ids = store.get_namespace_keys(todo_prefix:sub(1, -2)) or {}
	local code_ids = store.get_namespace_keys(code_prefix:sub(1, -2)) or {}

	local actual = {
		todo_links = 0,
		code_links = 0,
		active_todo = 0,
		active_code = 0,
		archived_todo = 0,
		archived_code = 0,
	}

	for _, id in ipairs(todo_ids) do
		local link = store.get_key(todo_prefix .. id)
		if link then
			actual.todo_links = actual.todo_links + 1
			if is_link_active(link) then
				actual.active_todo = actual.active_todo + 1
			else
				actual.archived_todo = actual.archived_todo + 1
			end
		end
	end

	for _, id in ipairs(code_ids) do
		local link = store.get_key(code_prefix .. id)
		if link then
			actual.code_links = actual.code_links + 1
			if is_link_active(link) then
				actual.active_code = actual.active_code + 1
			else
				actual.archived_code = actual.archived_code + 1
			end
		end
	end

	return {
		meta = {
			todo_links = meta.todo_links,
			code_links = meta.code_links,
			active_todo = meta.active_todo_links,
			active_code = meta.active_code_links,
			archived_todo = meta.archived_todo_links,
			archived_code = meta.archived_code_links,
		},
		actual = actual,
		diff = {
			todo_links = meta.todo_links - actual.todo_links,
			code_links = meta.code_links - actual.code_links,
			active_todo = meta.active_todo_links - actual.active_todo,
			active_code = meta.active_code_links - actual.active_code,
		},
		needs_fix = meta.todo_links ~= actual.todo_links or meta.code_links ~= actual.code_links,
	}
end

--- ⭐ 新增：修复计数
function M.fix_counts()
	local diag = M.diagnose()
	if not diag.needs_fix then
		return true
	end

	local meta = get_meta_safe()
	meta.todo_links = diag.actual.todo_links
	meta.code_links = diag.actual.code_links
	meta.active_todo_links = diag.actual.active_todo
	meta.active_code_links = diag.actual.active_code
	meta.archived_todo_links = diag.actual.archived_todo
	meta.archived_code_links = diag.actual.archived_code
	meta.total_links = diag.actual.todo_links + diag.actual.code_links
	meta.last_sync = os.time()

	store.set_key("todo.meta", meta)
	return true
end

--- 获取项目根目录
function M.get_project_root()
	local meta = store.get_key("todo.meta") or {}
	if meta.project_root and meta.project_root ~= "" then
		return meta.project_root
	end
	return vim.fn.getcwd()
end

--- 获取元数据
function M.get()
	return get_meta_safe()
end

--- 更新元数据字段
function M.update(updates)
	local meta = get_meta_safe()
	for k, v in pairs(updates) do
		meta[k] = v
	end
	store.set_key("todo.meta", meta)
end

--- 重置元数据（用于测试）
function M.reset()
	local meta = {
		initialized = true,
		version = "2.0",
		created_at = os.time(),
		last_sync = os.time(),
		total_links = 0,
		todo_links = 0,
		code_links = 0,
		active_todo_links = 0,
		active_code_links = 0,
		archived_todo_links = 0,
		archived_code_links = 0,
		project_root = vim.fn.getcwd(),
	}
	store.set_key("todo.meta", meta)
	return true
end

return M
