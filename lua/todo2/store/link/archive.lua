-- lua/todo2/store/link/archive.lua
-- 归档数据层：只负责快照的存储管理，不处理业务逻辑
---@module "todo2.store.link.archive"

local M = {}

local store = require("todo2.store.nvim_store")
local hash = require("todo2.utils.hash")

---------------------------------------------------------------------
-- 快照管理（核心功能）
---------------------------------------------------------------------

---保存任务完整快照
---@param id string 任务ID
---@param task table 完整任务对象（必须包含 core, locations, timestamps 等字段）
---@param original_line? string 原始TODO行内容（可选，如果不传则尝试从文件读取）
---@return table 保存的快照对象
function M.save_task_snapshot(id, task, original_line)
	local snapshot_key = "todo.archive.snapshot." .. id

	-- 如果没有传入原始行，尝试从文件读取
	if not original_line and task.locations and task.locations.todo then
		local ok, lines = pcall(vim.fn.readfile, task.locations.todo.path)
		if ok and lines and lines[task.locations.todo.line] then
			original_line = lines[task.locations.todo.line]
		end
	end

	-- 解析原始行获取完整信息
	local file_line_info = nil
	if original_line then
		local checkbox = original_line:match("%[([^%[%]]-)%]")
		if checkbox then
			checkbox = "[" .. checkbox .. "]"
		end

		local indent = original_line:match("^(%s*)")

		local tag, content = original_line:match("%[%]%s*(%w+):%s*(.-)%s*{%#.-%}")
			or original_line:match("%[%]%s*(.-)%s*{%#.-%}")

		local id_from_line = original_line:match("{%#([^}]+)}")

		file_line_info = {
			raw = original_line,
			checkbox = checkbox,
			indent = indent,
			tag = tag,
			content = content,
			id = id_from_line,
			line_num = task.locations and task.locations.todo and task.locations.todo.line,
			path = task.locations and task.locations.todo and task.locations.todo.path,
		}
	end

	-- 获取代码上下文（仅保存行号，不保存代码内容）
	local code_context = nil
	if task.locations and task.locations.code and task.locations.code.path then
		code_context = {
			path = task.locations.code.path,
			line = task.locations.code.line,
			context = task.locations.code.context, -- 已有的上下文信息
		}
	end

	-- 保存完整快照
	local snapshot = {
		id = id,
		archived_at = os.time(),
		version = 6,

		original_line = file_line_info,

		core = {
			content = task.core.content,
			content_hash = task.core.content_hash,
			status = task.core.status,
			previous_status = task.core.previous_status,
			tags = vim.deepcopy(task.core.tags or {}),
			ai_executable = task.core.ai_executable,
			sync_status = task.core.sync_status,
		},

		locations = {
			todo = task.locations.todo and {
				path = task.locations.todo.path,
				line = task.locations.todo.line,
			} or nil,
			code = task.locations.code and {
				path = task.locations.code.path,
				line = task.locations.code.line,
				context = task.locations.code.context,
				context_updated_at = task.locations.code.context_updated_at,
			} or nil,
		},

		relations = task.relations and {
			parent_id = task.relations.parent_id,
			child_ids = vim.deepcopy(task.relations.child_ids or {}),
			level = task.relations.level,
			path_cache = vim.deepcopy(task.relations.path_cache or {}),
		} or nil,

		timestamps = {
			created = task.timestamps.created,
			updated = task.timestamps.updated,
			completed = task.timestamps.completed,
			archived = task.timestamps.archived,
			archived_reason = task.timestamps.archived_reason,
		},

		verified = task.verified ~= nil and task.verified or true,
		code_context = code_context,

		metadata = {
			has_todo = task.locations and task.locations.todo ~= nil,
			has_code = task.locations and task.locations.code ~= nil,
			has_relations = task.relations ~= nil,
			has_original_line = file_line_info ~= nil,
		},
	}

	local checksum_str = string.format(
		"%s:%s:%s:%s",
		id,
		snapshot.core.status or "unknown",
		snapshot.archived_at,
		tostring(snapshot.metadata.has_code)
	)
	snapshot.checksum = hash.hash(checksum_str)

	store.set_key(snapshot_key, snapshot)
	return snapshot
end

---获取任务快照
---@param id string 任务ID
---@return table? 快照对象，不存在返回nil
function M.get_task_snapshot(id)
	return store.get_key("todo.archive.snapshot." .. id)
end

---删除任务快照
---@param id string 任务ID
function M.delete_task_snapshot(id)
	store.delete_key("todo.archive.snapshot." .. id)
end

---获取所有任务快照
---@return table[] 快照对象数组，按归档时间倒序排列
function M.get_all_task_snapshots()
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

---从快照恢复任务（返回完整任务对象）
---@param id string 任务ID
---@return table? 恢复的任务对象
function M.restore_task_from_snapshot(id)
	local snapshot = M.get_task_snapshot(id)
	if not snapshot then
		return nil
	end

	local task = {
		id = snapshot.id,
		core = {
			content = snapshot.core.content,
			content_hash = snapshot.core.content_hash,
			status = snapshot.core.status,
			previous_status = snapshot.core.previous_status,
			tags = vim.deepcopy(snapshot.core.tags or {}),
			ai_executable = snapshot.core.ai_executable,
			sync_status = snapshot.core.sync_status or "local",
		},
		relations = snapshot.relations and {
			parent_id = snapshot.relations.parent_id,
			child_ids = vim.deepcopy(snapshot.relations.child_ids or {}),
			level = snapshot.relations.level,
			path_cache = vim.deepcopy(snapshot.relations.path_cache or {}),
		} or nil,
		timestamps = {
			created = snapshot.timestamps.created,
			updated = snapshot.timestamps.updated,
			completed = snapshot.timestamps.completed,
			archived = snapshot.timestamps.archived,
			archived_reason = snapshot.timestamps.archived_reason,
		},
		verified = snapshot.verified ~= nil and snapshot.verified or true,
		locations = {
			todo = snapshot.locations.todo and {
				path = snapshot.locations.todo.path,
				line = snapshot.locations.todo.line,
			} or nil,
			code = snapshot.locations.code and {
				path = snapshot.locations.code.path,
				line = snapshot.locations.code.line,
				context = snapshot.locations.code.context,
				context_updated_at = snapshot.locations.code.context_updated_at,
			} or nil,
		},
	}

	return task
end

return M
