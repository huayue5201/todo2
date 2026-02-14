-- lua/todo2/store/link.lua
-- 核心链接管理系统

local M = {}

local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local locator = require("todo2.store.locator")

---------------------------------------------------------------------
-- 配置常量
---------------------------------------------------------------------
local LINK_TYPE_CONFIG = {
	todo = "todo.links.todo.",
	code = "todo.links.code.",
}

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------
local function create_link(id, data, link_type)
	local now = os.time()
	local tag = data.tag or "TODO"

	local link = {
		id = id,
		type = link_type,
		path = index._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		tag = tag,
		status = data.status or types.STATUS.NORMAL,
		archived_at = nil,
		archived_reason = nil,
		created_at = data.created_at or now,
		updated_at = now,
		completed_at = nil,
		previous_status = nil,
		active = true,
		deleted_at = nil,
		deletion_reason = nil,
		restored_at = nil,
		line_verified = true,
		last_verified_at = nil,
		verification_failed_at = nil,
		verification_note = nil,
		context = data.context,
		context_matched = nil,
		context_similarity = nil,
		context_updated_at = nil,
		sync_version = 1,
		last_sync_at = nil,
		sync_status = "local",
		sync_pending = false,
		sync_conflict = false,
		content_hash = locator.calculate_content_hash(data.content or ""),
	}
	return link
end

local function get_link(id, link_type, verify_line)
	local key_prefix = link_type == "todo" and LINK_TYPE_CONFIG.todo or LINK_TYPE_CONFIG.code
	local key = key_prefix .. id
	local link = store.get_key(key)
	if not link then
		return nil
	end
	if verify_line then
		link = locator.locate_task(link)
		store.set_key(key, link)
	end
	return link
end

local function check_link_pair_integrity(todo_link, code_link, operation)
	if not todo_link and not code_link then
		return false, "链接ID不存在"
	end
	if todo_link and code_link then
		if todo_link.active == false or code_link.active == false then
			return false, "链接已被删除，不能修改状态"
		end
	end
	if (todo_link and not code_link) or (not todo_link and code_link) then
		return false, string.format("数据不一致：链接对只有一端存在 (操作: %s)", operation)
	end
	return true, nil
end

---------------------------------------------------------------------
-- 公共 API
---------------------------------------------------------------------
--- 添加TODO链接
function M.add_todo(id, data)
	local ok, link = pcall(create_link, id, data, types.LINK_TYPES.TODO_TO_CODE)
	if not ok then
		vim.notify("创建TODO链接失败: " .. link, vim.log.levels.ERROR)
		return false
	end
	store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)
	local meta = require("todo2.store.meta")
	meta.increment_links("todo")
	return true
end

--- 添加代码链接
function M.add_code(id, data)
	local ok, link = pcall(create_link, id, data, types.LINK_TYPES.CODE_TO_TODO)
	if not ok then
		vim.notify("创建代码链接失败: " .. link, vim.log.levels.ERROR)
		return false
	end
	store.set_key(LINK_TYPE_CONFIG.code .. id, link)
	index._add_id_to_file_index("todo.index.file_to_code", link.path, id)
	local meta = require("todo2.store.meta")
	meta.increment_links("code")
	return true
end

--- 获取TODO链接
--- @param id string 链接ID
--- @param opts table|nil
function M.get_todo(id, opts)
	opts = opts or {}
	return get_link(id, "todo", opts.verify_line ~= false)
end

--- 获取代码链接
--- @param id string 链接ID
--- @param opts table|nil
function M.get_code(id, opts)
	opts = opts or {}
	return get_link(id, "code", opts.verify_line ~= false)
end

--- 标记任务为完成
function M.mark_completed(id)
	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "mark_completed")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		if types.is_completed_status(todo_link.status) then
			return todo_link
		end
		todo_link.previous_status = todo_link.status
		todo_link.status = types.STATUS.COMPLETED
		todo_link.completed_at = os.time()
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		if types.is_completed_status(code_link.status) then
			return code_link
		end
		code_link.previous_status = code_link.status
		code_link.status = types.STATUS.COMPLETED
		code_link.completed_at = os.time()
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 重新打开任务
function M.reopen_link(id)
	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "reopen_link")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		if types.is_active_status(todo_link.status) then
			return todo_link
		end
		local target_status = todo_link.previous_status or types.STATUS.NORMAL
		if todo_link.status == types.STATUS.ARCHIVED then
			todo_link.archived_at = nil
			todo_link.archived_reason = nil
		end
		todo_link.status = target_status
		todo_link.completed_at = nil
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		if types.is_active_status(code_link.status) then
			return code_link
		end
		local target_status = code_link.previous_status or types.STATUS.NORMAL
		if code_link.status == types.STATUS.ARCHIVED then
			code_link.archived_at = nil
			code_link.archived_reason = nil
		end
		code_link.status = target_status
		code_link.completed_at = nil
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 更新活跃状态
function M.update_active_status(id, new_status)
	if not types.is_active_status(new_status) then
		vim.notify("活跃状态只能是: normal, urgent 或 waiting", vim.log.levels.ERROR)
		return nil
	end

	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "update_active_status")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		if not types.is_active_status(todo_link.status) then
			vim.notify("已完成的任务不能设置活跃状态", vim.log.levels.WARN)
			return nil
		end
		todo_link.status = new_status
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		if not types.is_active_status(code_link.status) then
			vim.notify("已完成的任务不能设置活跃状态", vim.log.levels.WARN)
			return nil
		end
		code_link.status = new_status
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 归档任务
function M.mark_archived(id, reason, opts)
	opts = opts or {}

	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "mark_archived")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		if not types.is_completed_status(todo_link.status) then
			vim.notify("未完成的任务不能归档", vim.log.levels.WARN)
			return nil
		end
		todo_link.status = types.STATUS.ARCHIVED
		todo_link.archived_at = os.time()
		todo_link.archived_reason = reason or "manual"
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		code_link.status = types.STATUS.ARCHIVED
		code_link.archived_at = os.time()
		code_link.archived_reason = reason or "manual"
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	-- 如果传入了代码快照，保存它
	if opts.code_snapshot then
		M.save_archive_snapshot(id, opts.code_snapshot, todo_link)
	end

	return results.todo or results.code
end

--- 取消归档
function M.unarchive_link(id)
	local todo_link = M.get_todo(id, { verify_line = true })
	local code_link = M.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "unarchive_link")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		if todo_link.status ~= types.STATUS.ARCHIVED then
			return todo_link
		end
		todo_link.status = types.STATUS.COMPLETED
		todo_link.archived_at = nil
		todo_link.archived_reason = nil
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		if code_link.status ~= types.STATUS.ARCHIVED then
			return code_link
		end
		code_link.status = types.STATUS.COMPLETED
		code_link.archived_at = nil
		code_link.archived_reason = nil
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

--- 硬删除TODO链接
function M.delete_todo(id)
	local link = store.get_key(LINK_TYPE_CONFIG.todo .. id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_todo", link.path, id)
		store.delete_key(LINK_TYPE_CONFIG.todo .. id)
		local meta = require("todo2.store.meta")
		meta.decrement_links("todo")
		return true
	end
	return false
end

--- 硬删除代码链接
function M.delete_code(id)
	local link = store.get_key(LINK_TYPE_CONFIG.code .. id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_code", link.path, id)
		store.delete_key(LINK_TYPE_CONFIG.code .. id)
		local meta = require("todo2.store.meta")
		meta.decrement_links("code")
		return true
	end
	return false
end

--- 硬删除链接对
function M.delete_link_pair(id)
	local todo_deleted = M.delete_todo(id)
	local code_deleted = M.delete_code(id)
	return todo_deleted or code_deleted
end

--- 获取所有TODO链接
function M.get_all_todo()
	local prefix = LINK_TYPE_CONFIG.todo:sub(1, -2)
	local ids = store.get_namespace_keys(prefix) or {}
	local result = {}
	for _, id in ipairs(ids) do
		local link = M.get_todo(id, { verify_line = false })
		if link and link.active ~= false then
			result[id] = link
		end
	end
	return result
end

--- 获取所有代码链接
function M.get_all_code()
	local prefix = LINK_TYPE_CONFIG.code:sub(1, -2)
	local ids = store.get_namespace_keys(prefix) or {}
	local result = {}
	for _, id in ipairs(ids) do
		local link = M.get_code(id, { verify_line = false })
		if link and link.active ~= false then
			result[id] = link
		end
	end
	return result
end

--- 获取已归档的链接
function M.get_archived_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = {}
	local all_todo = M.get_all_todo()
	for id, link in pairs(all_todo) do
		if link.status == types.STATUS.ARCHIVED and link.active ~= false then
			if cutoff_time == 0 or (link.archived_at and link.archived_at >= cutoff_time) then
				result[id] = result[id] or {}
				result[id].todo = link
			end
		end
	end
	local all_code = M.get_all_code()
	for id, link in pairs(all_code) do
		if link.status == types.STATUS.ARCHIVED and link.active ~= false then
			if cutoff_time == 0 or (link.archived_at and link.archived_at >= cutoff_time) then
				result[id] = result[id] or {}
				result[id].code = link
			end
		end
	end
	return result
end

---------------------------------------------------------------------
-- ⭐ 新增：归档快照管理
---------------------------------------------------------------------

--- 保存归档快照
--- @param id string
--- @param code_snapshot table
--- @param todo_snapshot table|nil
function M.save_archive_snapshot(id, code_snapshot, todo_snapshot)
	local snapshot_key = "todo.archive.snapshot." .. id
	local snapshot = {
		id = id,
		archived_at = os.time(),
		code = code_snapshot,
		todo = todo_snapshot or M.get_todo(id, { verify_line = false }),
	}
	store.set_key(snapshot_key, snapshot)
	return snapshot
end

--- 获取归档快照
--- @param id string
--- @return table|nil
function M.get_archive_snapshot(id)
	return store.get_key("todo.archive.snapshot." .. id)
end

--- 删除归档快照
--- @param id string
function M.delete_archive_snapshot(id)
	store.delete_key("todo.archive.snapshot." .. id)
end

--- 获取所有归档快照
--- @return table[]
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

	-- 按归档时间倒序排序
	table.sort(snapshots, function(a, b)
		return (a.archived_at or 0) > (b.archived_at or 0)
	end)

	return snapshots
end

--- 从快照恢复代码标记
--- @param id string
--- @param insert_pos number|nil
--- @return boolean, string, table|nil
function M.restore_from_snapshot(id, insert_pos)
	local snapshot = M.get_archive_snapshot(id)
	if not snapshot then
		return false, "找不到归档快照", nil
	end

	if not snapshot.code then
		return false, "快照中没有代码标记信息", snapshot
	end

	local code_data = snapshot.code

	-- 检查文件是否可写
	if vim.fn.filereadable(code_data.path) == 0 then
		return false, string.format("文件不存在: %s", code_data.path), snapshot
	end

	-- 确定插入位置
	local target_line = insert_pos
	if not target_line then
		-- 使用 locator 查找最佳位置
		local locator = require("todo2.store.locator")
		target_line = locator.find_restore_position(code_data)
	end

	-- 重新添加代码链接
	local success = M.add_code(id, {
		path = code_data.path,
		line = target_line,
		content = code_data.content,
		tag = code_data.tag,
		context = code_data.context,
	})

	if success then
		-- 恢复 TODO 状态
		local todo_link = M.get_todo(id, { verify_line = false })
		if todo_link and todo_link.status == types.STATUS.ARCHIVED then
			M.unarchive_link(id)
		end

		return true, string.format("已恢复代码标记到行 %d", target_line), snapshot
	else
		return false, "添加代码链接失败", snapshot
	end
end

--- 批量从快照恢复
--- @param ids string[]
--- @return table
function M.batch_restore_from_snapshots(ids)
	local result = {
		total = #ids,
		success = 0,
		failed = 0,
		skipped = 0,
		details = {},
	}

	for _, id in ipairs(ids) do
		local ok, msg, snapshot = M.restore_from_snapshot(id)
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
	end

	result.summary = string.format("批量恢复完成: 成功 %d, 失败 %d", result.success, result.failed)

	return result
end

function M.is_completed(id)
	local todo_link = M.get_todo(id, { verify_line = false })
	local code_link = M.get_code(id, { verify_line = false })
	if todo_link and code_link then
		return types.is_completed_status(todo_link.status) and types.is_completed_status(code_link.status)
	end
	return false
end

function M.is_archived(id)
	local todo_link = M.get_todo(id, { verify_line = false })
	local code_link = M.get_code(id, { verify_line = false })
	if todo_link and code_link then
		return todo_link.status == types.STATUS.ARCHIVED and code_link.status == types.STATUS.ARCHIVED
	end
	return false
end

return M
