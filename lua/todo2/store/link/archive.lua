-- lua/todo2/store/link/archive.lua
-- 归档管理：专门处理任务的归档、恢复和快照

local M = {}

local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local hash = require("todo2.utils.hash")
local core = require("todo2.store.link.core")

-- 警告记录
local warned = {}

---------------------------------------------------------------------
-- 归档任务
---------------------------------------------------------------------

---归档任务
---@param id string 任务ID
---@param reason? string 归档原因
---@return table? 归档后的任务
function M.archive_task(id, reason)
	local task = core.get_task(id)
	if not task then
		vim.notify("任务不存在", vim.log.levels.ERROR)
		return nil
	end

	-- 先保存快照
	M.save_archive_snapshot(id, task)

	-- 更新任务状态
	local now = os.time()
	task.core.previous_status = task.core.status
	task.core.status = types.STATUS.ARCHIVED
	task.timestamps.archived = now
	task.timestamps.archived_reason = reason or "manual"
	task.timestamps.updated = now

	core.save_task(id, task)
	return task
end

---------------------------------------------------------------------
-- 取消归档
---------------------------------------------------------------------

---取消归档任务
---@param id string 任务ID
---@param opts? { delete_snapshot?: boolean } 选项
---@return table? 恢复后的任务
function M.unarchive_task(id, opts)
	opts = opts or {}

	local snapshot = M.get_archive_snapshot(id)
	if not snapshot then
		vim.notify("找不到归档快照", vim.log.levels.ERROR)
		return nil
	end

	local task = core.get_task(id)
	if not task then
		return nil
	end

	-- 从快照恢复
	local now = os.time()
	task.core.status = task.core.previous_status or types.STATUS.NORMAL
	task.core.previous_status = nil
	task.timestamps.completed = nil
	task.timestamps.archived = nil
	task.timestamps.archived_reason = nil
	task.timestamps.updated = now

	-- 恢复上下文
	if snapshot.todo.context then
		if not task.locations.code then
			task.locations.code = {}
		end
		task.locations.code.context = snapshot.todo.context
	end

	core.save_task(id, task)

	if opts.delete_snapshot ~= false then
		M.delete_archive_snapshot(id)
	end

	return task
end

---------------------------------------------------------------------
-- 快照管理
---------------------------------------------------------------------

---保存归档快照
---@param id string 任务ID
---@param task table 任务对象
---@return table 快照对象
function M.save_archive_snapshot(id, task)
	local snapshot_key = "todo.archive.snapshot." .. id

	-- 获取代码上下文
	local code_context = nil
	if task.locations.code and task.locations.code.path and vim.fn.filereadable(task.locations.code.path) == 1 then
		local lines = vim.fn.readfile(task.locations.code.path)
		if lines and #lines > 0 and task.locations.code.line and task.locations.code.line <= #lines then
			local start_line = math.max(1, task.locations.code.line - 2)
			local end_line = math.min(#lines, task.locations.code.line + 2)
			code_context = {}
			for i = start_line, end_line do
				table.insert(code_context, {
					line_num = i,
					content = lines[i],
					is_target = (i == task.locations.code.line),
				})
			end
		end
	end

	local snapshot = {
		id = id,
		archived_at = os.time(),
		task = {
			id = task.id,
			content = task.core.content,
			tags = task.core.tags,
			status = task.core.status,
			previous_status = task.core.previous_status,
			completed_at = task.timestamps.completed,
			created_at = task.timestamps.created,
			updated_at = task.timestamps.updated,
			context = task.locations.code and task.locations.code.context,
			todo_path = task.locations.todo and task.locations.todo.path,
			todo_line = task.locations.todo and task.locations.todo.line,
			code_path = task.locations.code and task.locations.code.path,
			code_line = task.locations.code and task.locations.code.line,
			code_context = code_context,
		},
		metadata = {
			version = 4,
			has_todo = task.locations.todo ~= nil,
			has_code = task.locations.code ~= nil,
		},
	}

	-- 计算校验和
	local checksum_str = string.format(
		"%s:%s:%s:%s",
		id,
		snapshot.task.status or "unknown",
		snapshot.archived_at,
		tostring(snapshot.metadata.has_code)
	)
	snapshot.checksum = hash.hash(checksum_str)

	store.set_key(snapshot_key, snapshot)
	return snapshot
end

---获取归档快照
---@param id string 任务ID
---@return table? 快照对象
function M.get_archive_snapshot(id)
	return store.get_key("todo.archive.snapshot." .. id)
end

---删除归档快照
---@param id string 任务ID
function M.delete_archive_snapshot(id)
	store.delete_key("todo.archive.snapshot." .. id)
end

---获取所有归档快照
---@return table[] 快照数组（按归档时间倒序）
function M.get_all_archive_snapshots()
	local prefix = "todo.archive.snapshot."
	local keys = store.get_namespace_keys(prefix:sub(1, -2)) or {}
	local snapshots = {}

	for _, key in ipairs(keys) do
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
-- 快照恢复
---------------------------------------------------------------------

---从快照恢复任务
---@param id string 任务ID
---@return table? 恢复后的任务
function M.restore_from_snapshot(id)
	local snapshot = M.get_archive_snapshot(id)
	if not snapshot then
		return nil
	end

	local task = core.get_task(id)
	if not task then
		-- 如果任务不存在，从快照重建
		task = {
			id = id,
			core = {
				content = snapshot.task.content,
				content_hash = hash.hash(snapshot.task.content or ""),
				status = snapshot.task.previous_status or types.STATUS.NORMAL,
				tags = snapshot.task.tags or { "TODO" },
				sync_status = "local",
			},
			timestamps = {
				created = snapshot.task.created_at or os.time(),
				updated = os.time(),
				completed = snapshot.task.completed_at,
			},
			verification = {
				line_verified = true,
			},
			locations = {},
		}

		if snapshot.task.todo_path then
			task.locations.todo = {
				path = snapshot.task.todo_path,
				line = snapshot.task.todo_line or 1,
			}
		end

		if snapshot.task.code_path then
			task.locations.code = {
				path = snapshot.task.code_path,
				line = snapshot.task.code_line or 1,
				context = snapshot.task.context,
			}
		end

		core.save_task(id, task)
	end

	return task
end

---------------------------------------------------------------------
-- ⚠️ 废弃的函数（转发到status.lua）
---------------------------------------------------------------------

---@deprecated 请使用 status.is_archived()
function M.is_archived(id)
	if not warned.is_archived then
		vim.notify("[todo2] archive.is_archived is deprecated, use status.is_archived()", vim.log.levels.WARN)
		warned.is_archived = true
	end
	return require("todo2.store.link.status").is_archived(id)
end

return M
