-- lua/todo2/store/link/archive.lua
-- 归档和快照管理（纯数据层，不包含业务逻辑）

local M = {}

local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local hash = require("todo2.utils.hash")
local core = require("todo2.store.link.core")
local status = require("todo2.store.link.status")

local LINK_TYPE_CONFIG = {
	todo = "todo.links.todo.",
	code = "todo.links.code.",
}

---------------------------------------------------------------------
-- ⭐ 修改：只做状态变更，不做业务判断
---------------------------------------------------------------------
function M.mark_archived(id, reason, opts)
	opts = opts or {}

	local todo_link = core.get_todo(id, { verify_line = true })
	local code_link = core.get_code(id, { verify_line = true })

	-- ⭐ 只检查链接是否存在，不做业务规则判断
	if not todo_link and not code_link then
		vim.notify("链接ID不存在", vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		todo_link.previous_status = todo_link.status
		todo_link.status = types.STATUS.ARCHIVED
		todo_link.archived_at = os.time()
		todo_link.archived_reason = reason or "manual"
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		code_link.previous_status = code_link.previous_status or code_link.status
		code_link.status = types.STATUS.ARCHIVED
		code_link.archived_at = os.time()
		code_link.archived_reason = reason or "manual"
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	-- ⭐ 只保存快照，不关心快照内容
	if opts.code_snapshot then
		M.save_archive_snapshot(id, opts.code_snapshot, todo_link)
	end

	return results.todo or results.code
end

-- ⭐ 修改：只做状态恢复，不验证业务规则
function M.unarchive_link(id, opts)
	opts = opts or {}

	local snapshot = M.get_archive_snapshot(id)
	if not snapshot then
		vim.notify("找不到归档快照", vim.log.levels.ERROR)
		return nil
	end

	-- ⭐ 只做数据完整性校验，不做业务判断
	if not M._verify_snapshot_integrity(id, snapshot) then
		vim.notify("归档快照已损坏", vim.log.levels.ERROR)
		return nil
	end

	local todo_link = core.get_todo(id, { verify_line = true })
	local code_link = core.get_code(id, { verify_line = true })

	local results = {}

	if todo_link then
		M._restore_todo_from_snapshot(todo_link, snapshot)
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		-- ⭐ 只恢复状态，不处理物理删除
		code_link.status = types.STATUS.COMPLETED
		code_link.previous_status = nil
		code_link.updated_at = os.time()
		code_link.archived_at = nil
		code_link.archived_reason = nil
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	if opts.delete_snapshot ~= false then
		M.delete_archive_snapshot(id)
	end

	return results.todo or results.code
end

---------------------------------------------------------------------
-- 快照管理（保持不变）
---------------------------------------------------------------------
function M.save_archive_snapshot(id, code_snapshot, todo_snapshot)
	local snapshot_key = "todo.archive.snapshot." .. id
	local todo_link = todo_snapshot or core.get_todo(id, { verify_line = false })

	local snapshot = {
		id = id,
		archived_at = os.time(),
		code = code_snapshot,
		todo = M._extract_todo_snapshot(todo_link),
		metadata = {
			version = 2,
			has_context = todo_link and todo_link.context ~= nil,
			has_code = code_snapshot ~= nil, -- ⭐ 明确标记是否有代码
		},
	}

	snapshot.checksum = M._calculate_snapshot_checksum(id, snapshot)

	store.set_key(snapshot_key, snapshot)
	return snapshot
end

function M.get_archive_snapshot(id)
	return store.get_key("todo.archive.snapshot." .. id)
end

function M.delete_archive_snapshot(id)
	store.delete_key("todo.archive.snapshot." .. id)
end

function M.get_all_archive_snapshots()
	local prefix = "todo.archive.snapshot."
	local keys = store.get_namespace_keys(prefix:sub(1, -2)) or {}
	local snapshots = {}

	for _, key in ipairs(keys) do
		local id = key:sub(#prefix + 1)
		local snapshot = store.get_key(key)
		if snapshot then
			table.insert(snapshots, snapshot)
		end
	end

	table.sort(snapshots, function(a, b)
		return (a.archived_at or 0) > (b.archived_at or 0)
	end)

	return snapshots
end

---------------------------------------------------------------------
-- 保留：内部辅助函数（数据操作相关）
---------------------------------------------------------------------
function M._extract_todo_snapshot(todo_link)
	if not todo_link then
		return nil
	end

	return {
		id = todo_link.id,
		path = todo_link.path,
		line_num = todo_link.line,
		content = todo_link.content,
		tag = todo_link.tag,
		status = todo_link.status,
		previous_status = todo_link.previous_status,
		completed_at = todo_link.completed_at,
		created_at = todo_link.created_at,
		updated_at = todo_link.updated_at,
		archived_at = todo_link.archived_at,
		context = todo_link.context,
		line_verified = todo_link.line_verified,
		context_updated_at = todo_link.context_updated_at,
		-- ⭐ 新增：保存层级信息
		level = todo_link.level,
		indent = todo_link.indent,
	}
end

function M._calculate_snapshot_checksum(id, snapshot)
	local checksum_str = string.format(
		"%s:%s:%s:%s:%s",
		id,
		snapshot.todo.status or "unknown",
		snapshot.todo.completed_at or "0",
		snapshot.archived_at,
		tostring(snapshot.metadata and snapshot.metadata.has_code)
	)
	return hash.hash(checksum_str)
end

function M._verify_snapshot_integrity(id, snapshot)
	local expected = M._calculate_snapshot_checksum(id, snapshot)
	return snapshot.checksum == expected
end

-- ⭐ 修改：从快照恢复TODO数据（删除 pending_restore_status）
function M._restore_todo_from_snapshot(todo_link, snapshot)
	todo_link.status = types.STATUS.COMPLETED
	todo_link.completed_at = snapshot.todo.completed_at or os.time()
	todo_link.previous_status = snapshot.todo.previous_status
	todo_link.created_at = snapshot.todo.created_at
	todo_link.updated_at = os.time()
	todo_link.archived_at = nil
	todo_link.archived_reason = nil
	todo_link.context = snapshot.todo.context
	todo_link.line_verified = snapshot.todo.line_verified
	todo_link.level = snapshot.todo.level
	todo_link.indent = snapshot.todo.indent
end

return M
