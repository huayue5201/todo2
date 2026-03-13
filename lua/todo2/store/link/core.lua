-- lua/todo2/store/link/core.lua
-- 纯存储版：无 verify_line / 无自动定位 / 无隐式写回

local M = {}

local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local hash = require("todo2.utils.hash")

---------------------------------------------------------------------
-- 存储前缀
---------------------------------------------------------------------
local PREFIX = {
	todo = "todo.links.todo.",
	code = "todo.links.code.",
}

---------------------------------------------------------------------
-- 创建链接（TODO 或 CODE）
---------------------------------------------------------------------
local function create_link(id, data, link_type)
	local now = os.time()

	return {
		id = id,
		type = link_type,

		-- 位置
		path = index._normalize_path(data.path),
		line = data.line,

		-- 内容
		content = data.content or "",
		tag = data.tag or "TODO",
		content_hash = hash.hash(data.content or ""),

		-- 状态
		status = data.status or types.STATUS.NORMAL,
		previous_status = nil,

		-- 时间戳
		created_at = data.created_at or now,
		updated_at = now,
		completed_at = nil,

		-- 归档信息
		archived_at = nil,
		archived_reason = nil,

		-- 验证信息（保留字段但不再使用）
		line_verified = true,
		last_verified_at = nil,
		verification_failed_at = nil,
		verification_note = nil,

		-- 上下文
		context = data.context,
		context_matched = nil,
		context_similarity = nil,
		context_updated_at = data.context and now or nil,

		-- 同步状态
		sync_status = "local",

		-- AI 可执行标记
		ai_executable = data.ai_executable,
	}
end

---------------------------------------------------------------------
-- 内部：写入存储并更新索引
---------------------------------------------------------------------
local function write_link(id, link_type, link)
	local key = PREFIX[link_type] .. id
	store.set_key(key, link)
end

local function update_index(id, old_path, new_path, link_type)
	if old_path ~= new_path then
		local ns = link_type == "todo" and "todo.index.file_to_todo" or "todo.index.file_to_code"

		index._remove_id_from_file_index(ns, old_path, id)
		index._add_id_to_file_index(ns, new_path, id)
	end
end

---------------------------------------------------------------------
-- 添加 TODO 链接
---------------------------------------------------------------------
function M.add_todo(id, data)
	local link = create_link(id, data, types.LINK_TYPES.TODO_TO_CODE)
	write_link(id, "todo", link)
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)
	return true
end

---------------------------------------------------------------------
-- 添加 CODE 链接
---------------------------------------------------------------------
function M.add_code(id, data)
	local link = create_link(id, data, types.LINK_TYPES.CODE_TO_TODO)
	write_link(id, "code", link)
	index._add_id_to_file_index("todo.index.file_to_code", link.path, id)
	return true
end

---------------------------------------------------------------------
-- 获取链接（纯读取，不做定位）
---------------------------------------------------------------------
function M._get_link(id, link_type)
	local key = PREFIX[link_type] .. id
	return store.get_key(key)
end

function M.get_todo(id)
	return M._get_link(id, "todo")
end

function M.get_code(id)
	return M._get_link(id, "code")
end

---------------------------------------------------------------------
-- 更新链接（无自动定位）
---------------------------------------------------------------------
function M._update_link(id, link_type, updated)
	local key = PREFIX[link_type] .. id
	local old = store.get_key(key)
	if not old then
		return false
	end

	update_index(id, old.path, updated.path, link_type)

	updated.updated_at = os.time()
	store.set_key(key, updated)
	return true
end

---------------------------------------------------------------------
-- 更新 TODO（同步 CODE）
---------------------------------------------------------------------
function M.update_todo(id, updated)
	local ok = M._update_link(id, "todo", updated)
	if not ok then
		return false
	end

	-- 同步到 CODE
	local code = M.get_code(id)
	if code then
		local sync = false
		local new_code = vim.deepcopy(code)

		if new_code.content ~= updated.content then
			new_code.content = updated.content
			new_code.content_hash = updated.content_hash
			sync = true
		end
		if new_code.tag ~= updated.tag then
			new_code.tag = updated.tag
			sync = true
		end
		if new_code.ai_executable ~= updated.ai_executable then
			new_code.ai_executable = updated.ai_executable
			sync = true
		end

		if sync then
			new_code.updated_at = os.time()
			M.update_code(id, new_code)
		end
	end

	return true
end

---------------------------------------------------------------------
-- 更新 CODE（同步 TODO）
---------------------------------------------------------------------
function M.update_code(id, updated)
	local ok = M._update_link(id, "code", updated)
	if not ok then
		return false
	end

	-- 同步到 TODO
	local todo = M.get_todo(id)
	if todo then
		local sync = false
		local new_todo = vim.deepcopy(todo)

		if new_todo.content ~= updated.content then
			new_todo.content = updated.content
			new_todo.content_hash = updated.content_hash
			sync = true
		end
		if new_todo.tag ~= updated.tag then
			new_todo.tag = updated.tag
			sync = true
		end
		if new_todo.ai_executable ~= updated.ai_executable then
			new_todo.ai_executable = updated.ai_executable
			sync = true
		end

		if sync then
			new_todo.updated_at = os.time()
			M.update_todo(id, new_todo)
		end
	end

	return true
end

---------------------------------------------------------------------
-- 删除链接
---------------------------------------------------------------------
function M._delete_link(id, link_type)
	local key = PREFIX[link_type] .. id
	local link = store.get_key(key)
	if not link then
		return false
	end

	local ns = link_type == "todo" and "todo.index.file_to_todo" or "todo.index.file_to_code"

	index._remove_id_from_file_index(ns, link.path, id)
	store.delete_key(key)
	return true
end

function M.delete_todo(id)
	return M._delete_link(id, "todo")
end

function M.delete_code(id)
	return M._delete_link(id, "code")
end

function M.delete_link_pair(id)
	M.delete_todo(id)
	M.delete_code(id)
end

---------------------------------------------------------------------
-- 文件重命名修复（仍然需要）
---------------------------------------------------------------------
function M.handle_file_rename(old_path, new_path)
	if not old_path or old_path == "" or not new_path or new_path == "" then
		return { updated = 0, affected_ids = {} }
	end

	local norm_old = index._normalize_path(old_path)
	local norm_new = index._normalize_path(new_path)
	if norm_old == norm_new then
		return { updated = 0, affected_ids = {} }
	end

	local updated = 0
	local affected_ids = {}

	-- TODO 链接
	do
		local prefix = PREFIX.todo
		local ids = store.get_namespace_keys("todo.links.todo") or {}
		for _, key in ipairs(ids) do
			local id = key:sub(#prefix + 1)
			local link = store.get_key(prefix .. id)
			if link and link.path == norm_old then
				local old = link.path
				link.path = norm_new
				update_index(id, old, link.path, "todo")
				link.updated_at = os.time()
				store.set_key(prefix .. id, link)
				table.insert(affected_ids, id)
				updated = updated + 1
			end
		end
	end

	-- CODE 链接
	do
		local prefix = PREFIX.code
		local ids = store.get_namespace_keys("todo.links.code") or {}
		for _, key in ipairs(ids) do
			local id = key:sub(#prefix + 1)
			local link = store.get_key(prefix .. id)
			if link and link.path == norm_old then
				local old = link.path
				link.path = norm_new
				update_index(id, old, link.path, "code")
				link.updated_at = os.time()
				store.set_key(prefix .. id, link)
				if not vim.tbl_contains(affected_ids, id) then
					table.insert(affected_ids, id)
				end
				updated = updated + 1
			end
		end
	end

	-- 清理解析缓存
	local ok, scheduler = pcall(require, "todo2.render.scheduler")
	if ok and scheduler and scheduler.invalidate_cache then
		pcall(scheduler.invalidate_cache, norm_old)
		pcall(scheduler.invalidate_cache, norm_new)
	end

	return {
		updated = updated,
		affected_ids = affected_ids,
		old_path = norm_old,
		new_path = norm_new,
	}
end

return M
