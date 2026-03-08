-- lua/todo2/store/link/core.lua
-- 链接核心 CRUD（无软删除版本 + 无 meta.increment/decrement）

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

		-- 验证信息
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
-- 添加 TODO 链接（无 meta.increment）
---------------------------------------------------------------------
function M.add_todo(id, data)
	local link = create_link(id, data, types.LINK_TYPES.TODO_TO_CODE)
	write_link(id, "todo", link)
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)
	return true
end

---------------------------------------------------------------------
-- 添加 CODE 链接（无 meta.increment）
---------------------------------------------------------------------
function M.add_code(id, data)
	local link = create_link(id, data, types.LINK_TYPES.CODE_TO_TODO)
	write_link(id, "code", link)
	index._add_id_to_file_index("todo.index.file_to_code", link.path, id)
	return true
end

---------------------------------------------------------------------
-- 获取链接（可选 verify_line）
---------------------------------------------------------------------
function M._get_link(id, link_type, opts)
	opts = opts or {}
	local key = PREFIX[link_type] .. id
	local link = store.get_key(key)
	if not link then
		return nil
	end

	-- 自动定位（可选）
	if opts.verify_line or opts.force_verify then
		local locator = require("todo2.store.locator")
		local ok, verified = pcall(locator.locate_task, link)
		if ok and verified and verified.line then
			if verified.path ~= link.path or verified.line ~= link.line then
				update_index(id, link.path, verified.path, link_type)
				verified.updated_at = os.time()
				write_link(id, link_type, verified)
				link = verified
			end
		end
	end

	return link
end

function M.get_todo(id, opts)
	return M._get_link(id, "todo", opts)
end

function M.get_code(id, opts)
	return M._get_link(id, "code", opts)
end

---------------------------------------------------------------------
-- 更新链接（无软删除检查）
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
-- 更新 TODO（带同步）
---------------------------------------------------------------------
function M.update_todo(id, updated)
	local ok = M._update_link(id, "todo", updated)
	if not ok then
		return false
	end

	-- 同步到 CODE
	local code = M.get_code(id, { verify_line = false })
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

		if sync then
			new_code.updated_at = os.time()
			M.update_code(id, new_code)
		end
	end

	return true
end

---------------------------------------------------------------------
-- 更新 CODE（带同步）
---------------------------------------------------------------------
function M.update_code(id, updated)
	local ok = M._update_link(id, "code", updated)
	if not ok then
		return false
	end

	-- 同步到 TODO
	local todo = M.get_todo(id, { verify_line = false })
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

		if sync then
			new_todo.updated_at = os.time()
			M.update_todo(id, new_todo)
		end
	end

	return true
end

---------------------------------------------------------------------
-- 删除链接（彻底删除，无 meta.decrement）
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
	local a = M.delete_todo(id)
	local b = M.delete_code(id)
	return a or b
end

return M
