-- lua/todo2/store/link/archive.lua
-- 归档和快照管理（增强上下文支持）

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
-- 归档操作
---------------------------------------------------------------------
function M.mark_archived(id, reason, opts)
	opts = opts or {}

	local todo_link = core.get_todo(id, { verify_line = true })
	local code_link = core.get_code(id, { verify_line = true })

	local ok, err = status._check_pair_integrity(todo_link, code_link, "mark_archived")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		todo_link.previous_status = todo_link.status -- ⭐ 保存之前的状态
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

	if opts.code_snapshot then
		M.save_archive_snapshot(id, opts.code_snapshot, todo_link)
	end

	return results.todo or results.code
end

function M.unarchive_link(id, opts)
	opts = opts or {}

	local snapshot = M.get_archive_snapshot(id)
	if not snapshot then
		vim.notify("找不到归档快照，无法恢复", vim.log.levels.ERROR)
		return nil
	end

	-- 验证快照完整性
	if not M._verify_snapshot_integrity(id, snapshot) then
		vim.notify("归档快照已损坏，无法恢复", vim.log.levels.ERROR)
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
-- 快照管理
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
		},
	}

	-- 计算校验和
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
-- 从快照恢复
---------------------------------------------------------------------
function M.restore_from_snapshot(id, insert_pos, opts)
	opts = opts or {}
	local snapshot = M.get_archive_snapshot(id)
	if not snapshot then
		return false, "找不到归档快照", nil
	end

	if not snapshot.code then
		return false, "快照中没有代码标记信息", snapshot
	end

	local code_data = snapshot.code
	if vim.fn.filereadable(code_data.path) == 0 then
		return false, string.format("文件不存在: %s", code_data.path), snapshot
	end

	local target_line = M._determine_target_line(snapshot, insert_pos, opts)

	if not target_line then
		return false, "无法定位恢复位置", snapshot
	end

	local new_context = M._get_or_create_context(code_data.path, target_line, opts.updated_context)

	local success = core.add_code(id, {
		path = code_data.path,
		line = target_line,
		content = code_data.content,
		tag = code_data.tag,
		context = new_context,
	})

	if success then
		return true, string.format("已恢复代码标记到行 %d", target_line), snapshot
	else
		return false, "添加代码链接失败", snapshot
	end
end

function M.batch_restore_from_snapshots(ids, opts)
	opts = opts or {}
	local result = {
		total = #ids,
		success = 0,
		failed = 0,
		skipped = 0,
		details = {},
	}

	for _, id in ipairs(ids) do
		local snapshot = M.get_archive_snapshot(id)
		if not snapshot then
			table.insert(result.details, {
				id = id,
				success = false,
				message = "快照不存在",
				has_code = false,
			})
			result.failed = result.failed + 1
			goto continue
		end

		local ok, msg = M.restore_from_snapshot(id, nil, {
			use_context = opts.use_context,
			similarity_threshold = opts.similarity_threshold,
		})

		table.insert(result.details, {
			id = id,
			success = ok,
			message = msg,
			has_code = snapshot and snapshot.code ~= nil,
		})

		if ok then
			result.success = result.success + 1
		else
			result.failed = result.failed + 1
		end

		::continue::
	end

	result.summary = string.format("批量恢复完成: 成功 %d, 失败 %d", result.success, result.failed)
	return result
end

---------------------------------------------------------------------
-- 内部辅助函数
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
		previous_status = todo_link.previous_status, -- ⭐ 保存之前的状态
		completed_at = todo_link.completed_at,
		created_at = todo_link.created_at,
		updated_at = todo_link.updated_at,
		archived_at = todo_link.archived_at,
		context = todo_link.context,
		line_verified = todo_link.line_verified,
		context_updated_at = todo_link.context_updated_at,
	}
end

function M._calculate_snapshot_checksum(id, snapshot)
	local checksum_str = string.format(
		"%s:%s:%s:%s",
		id,
		snapshot.todo.status or "unknown",
		snapshot.todo.completed_at or "0",
		snapshot.archived_at
	)
	return hash.hash(checksum_str)
end

function M._verify_snapshot_integrity(id, snapshot)
	local expected = M._calculate_snapshot_checksum(id, snapshot)
	return snapshot.checksum == expected
end

-- ⭐ 从快照恢复 TODO 任务（复用 previous_status）
function M._restore_todo_from_snapshot(todo_link, snapshot)
	todo_link.status = types.STATUS.COMPLETED
	todo_link.completed_at = snapshot.todo.completed_at or os.time()
	todo_link.previous_status = snapshot.todo.previous_status -- ⭐ 恢复之前的状态
	todo_link.created_at = snapshot.todo.created_at
	todo_link.updated_at = os.time()
	todo_link.archived_at = nil
	todo_link.archived_reason = nil
	todo_link.context = snapshot.todo.context
	todo_link.line_verified = snapshot.todo.line_verified

	-- 如果归档前是活跃状态，设置待恢复标记
	if types.is_active_status(snapshot.todo.status) then
		todo_link.pending_restore_status = snapshot.todo.status
	end
end

function M._determine_target_line(snapshot, insert_pos, opts)
	if insert_pos then
		return insert_pos
	end

	if opts.use_context ~= false and snapshot.todo and snapshot.todo.context then
		local locator = require("todo2.store.locator")
		local context_result = locator.locate_by_context_fingerprint(
			snapshot.code.path,
			snapshot.todo.context,
			opts.similarity_threshold or 70
		)

		if context_result then
			-- 更新快照中的上下文
			snapshot.todo.context = context_result.context
			store.set_key("todo.archive.snapshot." .. snapshot.id, snapshot)
			return context_result.line
		end
	end

	-- 回退到原有的 find_restore_position
	local locator = require("todo2.store.locator")
	return locator.find_restore_position(snapshot.code)
end

function M._get_or_create_context(filepath, target_line, updated_context)
	if updated_context then
		return updated_context
	end

	local context_module = require("todo2.store.context")

	if vim.api.nvim_buf_is_valid(0) and vim.fn.expand("%:p") == filepath then
		return context_module.build_from_buffer(0, target_line):to_storable()
	else
		local lines = vim.fn.readfile(filepath)
		local prev = target_line > 1 and lines[target_line - 1] or ""
		local curr = lines[target_line]
		local next = target_line < #lines and lines[target_line + 1] or ""
		return context_module.build(prev, curr, next)
	end
end

return M
