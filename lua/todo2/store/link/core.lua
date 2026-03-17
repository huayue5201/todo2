-- lua/todo2/store/link/core.lua
-- 最终纯净版：只保留内部格式操作

local M = {}

local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local hash = require("todo2.utils.hash")

local INTERNAL_PREFIX = "todo.links.internal."

---------------------------------------------------------------------
-- 内部函数
---------------------------------------------------------------------

--- 获取内部格式的任务
function M._get_internal(id)
	return store.get_key(INTERNAL_PREFIX .. id)
end

--- 保存内部格式的任务
function M._save_internal(id, data)
	store.set_key(INTERNAL_PREFIX .. id, data)
end

--- 删除内部格式的任务
function M._delete_internal(id)
	store.delete_key(INTERNAL_PREFIX .. id)
end

--- 更新索引
local function update_index(id, old_path, new_path, location_type)
	if old_path == new_path then
		return
	end

	local ns = location_type == "todo" and "todo.index.file_to_todo" or "todo.index.file_to_code"

	if old_path then
		index._remove_id_from_file_index(ns, old_path, id)
	end
	if new_path then
		index._add_id_to_file_index(ns, new_path, id)
	end
end

---------------------------------------------------------------------
-- ⭐ 新增：行号管理函数
---------------------------------------------------------------------

--- 验证并更新任务的行号
--- @param id string 任务ID
--- @param file_path string 文件路径
--- @param line_num number 当前行号
--- @param line_content string 行内容
--- @return boolean 是否更新了行号
function M.verify_and_update_line(id, file_path, line_num, line_content)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	-- 确保 locations 结构存在
	if not task.locations then
		task.locations = {}
	end
	if not task.locations.todo then
		task.locations.todo = {}
	end

	local stored_line = task.locations.todo.line
	local stored_file = task.locations.todo.path

	-- 情况1：没有存储的行号 → 使用当前行号
	if not stored_line then
		task.locations.todo.line = line_num
		task.locations.todo.path = file_path
		task.verification.line_verified = true
		task.verification.last_verified_at = os.time()
		M._save_internal(id, task)
		return true
	end

	-- 情况2：文件路径不同 → 更新为当前文件
	if stored_file ~= file_path then
		task.locations.todo.line = line_num
		task.locations.todo.path = file_path
		task.verification.line_verified = true
		task.verification.last_verified_at = os.time()
		M._save_internal(id, task)
		return true
	end

	-- 情况3：同一文件，验证行号
	if stored_file == file_path then
		-- 如果存储的行号就是当前行号，直接验证通过
		if stored_line == line_num then
			if not task.verification.line_verified then
				task.verification.line_verified = true
				task.verification.last_verified_at = os.time()
				M._save_internal(id, task)
			end
			return true
		end

		-- 验证行内容是否匹配（防止误判）
		local lines = vim.fn.readfile(file_path)
		local stored_content = lines[stored_line]
		local escaped_content = task.core.content:gsub("[%-%.%+%[%]%*%?%^%$%(%)]", "%%%0")

		-- 如果存储的行号对应的内容匹配，说明是内容没变但行号变了（插入/删除行导致）
		if stored_content and stored_content:match(escaped_content) then
			-- 内容匹配，说明任务确实在那行，更新行号
			task.locations.todo.line = line_num
			task.verification.line_verified = true
			task.verification.last_verified_at = os.time()
			M._save_internal(id, task)
			return true
		else
			-- 内容不匹配，说明任务可能移动了，需要重新查找
			for i, content in ipairs(lines) do
				if content:match(escaped_content) then
					task.locations.todo.line = i
					task.locations.todo.path = file_path
					task.verification.line_verified = true
					task.verification.last_verified_at = os.time()
					M._save_internal(id, task)
					return true
				end
			end
		end
	end

	return false
end

--- 获取任务的权威行号
--- @param id string 任务ID
--- @param default_line number 默认行号
--- @return number 权威行号
function M.get_authoritative_line(id, default_line)
	local task = M._get_internal(id)
	if not task or not task.locations or not task.locations.todo then
		return default_line
	end
	return task.locations.todo.line or default_line
end

---------------------------------------------------------------------
-- 新接口（直接操作内部格式）
---------------------------------------------------------------------

--- 获取任务（返回内部格式）
function M.get_task(id)
	return M._get_internal(id)
end

--- 获取TODO位置信息
function M.get_todo_location(id)
	local task = M._get_internal(id)
	return task and task.locations.todo
end

--- 获取代码位置信息
function M.get_code_location(id)
	local task = M._get_internal(id)
	return task and task.locations.code
end

--- 保存任务
function M.save_task(id, task)
	if not task then
		return false
	end
	task.timestamps.updated = os.time()
	M._save_internal(id, task)
	return true
end

--- 删除任务
function M.delete_task(id)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	if task.locations.todo then
		index._remove_id_from_file_index("todo.index.file_to_todo", task.locations.todo.path, id)
	end
	if task.locations.code then
		index._remove_id_from_file_index("todo.index.file_to_code", task.locations.code.path, id)
	end

	M._delete_internal(id)
	return true
end

--- 创建任务
function M.create_task(data)
	local id = require("todo2.utils.id").generate()
	local now = os.time()

	local task = {
		id = id,
		core = {
			content = data.content or "",
			content_hash = hash.hash(data.content or ""),
			status = data.status or types.STATUS.NORMAL,
			previous_status = nil,
			tags = data.tags or { "TODO" },
			ai_executable = data.ai_executable,
			sync_status = "local",
		},
		timestamps = {
			created = now,
			updated = now,
			completed = nil,
			archived = nil,
			archived_reason = nil,
		},
		verification = {
			line_verified = true,
			last_verified_at = nil,
		},
		locations = {},
	}

	if data.todo_path then
		task.locations.todo = {
			path = index._normalize_path(data.todo_path),
			line = data.todo_line or 1,
		}
		index._add_id_to_file_index("todo.index.file_to_todo", task.locations.todo.path, id)
	end

	if data.code_path then
		task.locations.code = {
			path = index._normalize_path(data.code_path),
			line = data.code_line or 1,
			context = data.context,
			context_updated_at = data.context and now or nil,
		}
		index._add_id_to_file_index("todo.index.file_to_code", task.locations.code.path, id)
	end

	M._save_internal(id, task)
	return id
end

--- 更新任务内容
function M.update_content(id, content)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	task.core.content = content
	task.core.content_hash = hash.hash(content)
	task.timestamps.updated = os.time()

	M._save_internal(id, task)
	return true
end

--- 更新任务状态
function M.update_status(id, status)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	task.core.previous_status = task.core.status
	task.core.status = status
	task.timestamps.updated = os.time()

	if status == types.STATUS.COMPLETED then
		task.timestamps.completed = os.time()
	elseif status == types.STATUS.ARCHIVED then
		task.timestamps.archived = os.time()
	end

	M._save_internal(id, task)
	return true
end

--- 更新任务标签
function M.update_tags(id, tags)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	task.core.tags = tags
	task.timestamps.updated = os.time()

	M._save_internal(id, task)
	return true
end

--- 更新AI可执行标记
function M.update_ai_executable(id, value)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	task.core.ai_executable = value
	task.timestamps.updated = os.time()

	M._save_internal(id, task)
	return true
end

--- 更新TODO位置
function M.update_todo_location(id, path, line)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	local old_path = task.locations.todo and task.locations.todo.path
	local new_path = index._normalize_path(path)

	task.locations.todo = {
		path = new_path,
		line = line or 1,
	}
	task.timestamps.updated = os.time()
	task.verification.line_verified = false

	M._save_internal(id, task)
	update_index(id, old_path, new_path, "todo")

	return true
end

--- 更新代码位置
function M.update_code_location(id, path, line, context)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	local old_path = task.locations.code and task.locations.code.path
	local new_path = index._normalize_path(path)

	task.locations.code = {
		path = new_path,
		line = line or 1,
		context = context,
		context_updated_at = context and os.time() or nil,
	}
	task.timestamps.updated = os.time()
	task.verification.line_verified = false

	M._save_internal(id, task)
	update_index(id, old_path, new_path, "code")

	return true
end

---------------------------------------------------------------------
-- 批量操作
---------------------------------------------------------------------

--- 获取所有任务
function M.get_all_tasks()
	local keys = store.get_namespace_keys("todo.links.internal") or {}
	local result = {}

	for _, key in ipairs(keys) do
		local id = key:match("todo%.links%.internal%.(.*)$")
		if id then
			local task = store.get_key(key)
			if task then
				result[id] = task
			end
		end
	end

	return result
end

--- 获取所有有TODO位置的任务
function M.get_all_todo_tasks()
	local all = M.get_all_tasks()
	local result = {}

	for id, task in pairs(all) do
		if task.locations.todo then
			result[id] = task
		end
	end

	return result
end

--- 获取所有有代码位置的任务
function M.get_all_code_tasks()
	local all = M.get_all_tasks()
	local result = {}

	for id, task in pairs(all) do
		if task.locations.code then
			result[id] = task
		end
	end

	return result
end

---------------------------------------------------------------------
-- 文件重命名处理
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

	local result = {
		updated = 0,
		affected_ids = {},
	}

	local keys = store.get_namespace_keys("todo.links.internal") or {}
	for _, key in ipairs(keys) do
		local id = key:match("todo%.links%.internal%.(.*)$")
		if id then
			local task = store.get_key(key)
			local changed = false

			if task.locations.todo and task.locations.todo.path == norm_old then
				task.locations.todo.path = norm_new
				changed = true
				index._remove_id_from_file_index("todo.index.file_to_todo", norm_old, id)
				index._add_id_to_file_index("todo.index.file_to_todo", norm_new, id)
			end

			if task.locations.code and task.locations.code.path == norm_old then
				task.locations.code.path = norm_new
				changed = true
				index._remove_id_from_file_index("todo.index.file_to_code", norm_old, id)
				index._add_id_to_file_index("todo.index.file_to_code", norm_new, id)
			end

			if changed then
				task.timestamps.updated = os.time()
				store.set_key(key, task)
				table.insert(result.affected_ids, id)
				result.updated = result.updated + 1
			end
		end
	end

	return result
end

return M
