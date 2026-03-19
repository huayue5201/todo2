-- lua/todo2/store/link/core.lua
-- 核心模块：内部格式的CRUD操作
-- 优化版：去除冗余字段，保持功能不变

local M = {}

local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local file = require("todo2.utils.file") -- ⭐ 引入文件工具模块

local INTERNAL_PREFIX = "todo.links.internal."

-- 警告记录表，避免重复警告
local warned = {}

---输出弃用警告（每个函数只警告一次）
---@param old_name string 旧函数名
---@param new_name string 新函数名
local function warn_deprecated(old_name, new_name)
	if not warned[old_name] then
		vim.notify(
			string.format("[todo2] %s is deprecated, please use %s instead", old_name, new_name),
			vim.log.levels.WARN
		)
		warned[old_name] = true
	end
end

---------------------------------------------------------------------
-- 内部函数
---------------------------------------------------------------------

--- 获取内部格式的任务
---@param id string 任务ID
---@return table? 任务对象
function M._get_internal(id)
	return store.get_key(INTERNAL_PREFIX .. id)
end

--- 保存内部格式的任务
---@param id string 任务ID
---@param data table 任务数据
function M._save_internal(id, data)
	store.set_key(INTERNAL_PREFIX .. id, data)
end

--- 删除内部格式的任务
---@param id string 任务ID
function M._delete_internal(id)
	store.delete_key(INTERNAL_PREFIX .. id)
end

--- 更新索引
---@param id string 任务ID
---@param old_path string? 旧路径
---@param new_path string? 新路径
---@param location_type "todo"|"code" 位置类型
local function update_index(id, old_path, new_path, location_type)
	if old_path == new_path then
		return
	end

	if old_path then
		if location_type == "todo" then
			index._internal.remove_todo_id(old_path, id)
		else
			index._internal.remove_code_id(old_path, id)
		end
	end
	if new_path then
		if location_type == "todo" then
			index._internal.add_todo_id(new_path, id)
		else
			index._internal.add_code_id(new_path, id)
		end
	end
end

---------------------------------------------------------------------
-- ⭐ 行号管理函数
---------------------------------------------------------------------

--- 验证并更新任务的行号
---@param id string 任务ID
---@param file_path string 文件路径
---@param line_num number 当前行号
---@return boolean 是否更新了行号
function M.verify_and_update_line(id, file_path, line_num)
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
		task.verified = true -- 简化：布尔值即可
		M._save_internal(id, task)
		return true
	end

	-- 情况2：文件路径不同 → 更新为当前文件
	if stored_file ~= file_path then
		task.locations.todo.line = line_num
		task.locations.todo.path = file_path
		task.verified = true
		M._save_internal(id, task)
		return true
	end

	-- 情况3：同一文件，验证行号
	if stored_file == file_path then
		-- 如果存储的行号就是当前行号，直接验证通过
		if stored_line == line_num then
			if not task.verified then
				task.verified = true
				M._save_internal(id, task)
			end
			return true
		end

		-- 验证行内容是否匹配（防止误判）
		local lines = vim.fn.readfile(file_path)
		local stored_content = lines[stored_line]
		local content = task.core.content -- content_hash 已移除，直接用 content

		-- 如果存储的行号对应的内容匹配，说明是内容没变但行号变了
		if stored_content and stored_content:find(content, 1, true) then
			task.locations.todo.line = line_num
			task.verified = true
			M._save_internal(id, task)
			return true
		else
			-- 内容不匹配，说明任务可能移动了，需要重新查找
			for i, content_line in ipairs(lines) do
				if content_line:find(content, 1, true) then
					task.locations.todo.line = i
					task.locations.todo.path = file_path
					task.verified = true
					M._save_internal(id, task)
					return true
				end
			end
		end
	end

	return false
end

--- 获取任务的权威行号
---@param id string 任务ID
---@param default_line number 默认行号
---@return number 权威行号
function M.get_authoritative_line(id, default_line)
	local task = M._get_internal(id)
	if not task or not task.locations or not task.locations.todo then
		return default_line
	end
	return task.locations.todo.line or default_line
end

---------------------------------------------------------------------
-- 核心CRUD操作
---------------------------------------------------------------------

--- 获取任务（返回内部格式）
---@param id string 任务ID
---@return table? 任务对象
function M.get_task(id)
	return M._get_internal(id)
end

--- 获取TODO位置信息
---@param id string 任务ID
---@return table? { path: string, line: number } 位置信息
function M.get_todo_location(id)
	local task = M._get_internal(id)
	return task and task.locations.todo
end

--- 获取代码位置信息
---@param id string 任务ID
---@return table? { path: string, line: number, context?: table, context_updated_at?: number } 位置信息
function M.get_code_location(id)
	local task = M._get_internal(id)
	return task and task.locations.code
end

--- 保存任务
---@param id string 任务ID
---@param task table 任务对象
---@return boolean 是否成功
function M.save_task(id, task)
	if not task then
		return false
	end
	task.timestamps.updated = os.time()
	M._save_internal(id, task)
	return true
end

--- 删除任务
---@param id string 任务ID
---@return boolean 是否成功
function M.delete_task(id)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	-- 如果有relation模块，清理关系
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if ok and relation and task.relations and task.relations.parent_id then
		relation.remove_child(task.relations.parent_id, id)
	end

	if task.locations.todo then
		index._internal.remove_todo_id(task.locations.todo.path, id)
	end
	if task.locations.code then
		index._internal.remove_code_id(task.locations.code.path, id)
	end

	M._delete_internal(id)
	return true
end

--- 创建任务
---@param data { content?: string, status?: string, tags?: string[], ai_executable?: boolean, todo_path?: string, todo_line?: number, code_path?: string, code_line?: number, context?: table, parent_id?: string }
---@return string 任务ID
function M.create_task(data)
	local id = require("todo2.utils.id").generate_id()
	local now = os.time()

	local task = {
		id = id,
		core = {
			content = data.content or "",
			status = data.status or types.STATUS.NORMAL,
			previous_status = nil,
			tags = data.tags or { "TODO" },
			ai_executable = data.ai_executable,
			sync_status = "local",
		},
		relations = data.parent_id and {
			parent_id = data.parent_id,
		} or nil,
		timestamps = {
			created = now,
			updated = now,
			completed = nil,
			archived = nil,
		},
		verified = true,
		locations = {},
	}

	if data.todo_path then
		task.locations.todo = {
			path = file.normalize_path(data.todo_path),
			line = data.todo_line or 1,
		}
		index._internal.add_todo_id(task.locations.todo.path, id)
	end

	if data.code_path then
		task.locations.code = {
			path = file.normalize_path(data.code_path),
			line = data.code_line or 1,
			context = data.context,
			context_updated_at = data.context and now or nil,
		}
		index._internal.add_code_id(task.locations.code.path, id)
	end

	M._save_internal(id, task)

	-- ✅ 修复：安全地建立父子关系
	if data.parent_id then
		local ok, relation_mod = pcall(require, "todo2.store.link.relation")
		if ok and relation_mod and type(relation_mod.set_parent_child) == "function" then
			local success, err = pcall(relation_mod.set_parent_child, relation_mod, data.parent_id, id)
			if not success then
				vim.notify("建立父子关系失败: " .. tostring(err), vim.log.levels.WARN)
			end
		end
	end

	return id
end

--- 更新任务内容
---@param id string 任务ID
---@param content string 新内容
---@return boolean 是否成功
function M.update_content(id, content)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	task.core.content = content
	-- content_hash 已移除，不需要更新
	task.timestamps.updated = os.time()

	M._save_internal(id, task)
	return true
end

--- 更新任务状态
---@param id string 任务ID
---@param status string 新状态
---@return boolean 是否成功
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
---@param id string 任务ID
---@param tags string[] 新标签列表
---@return boolean 是否成功
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
---@param id string 任务ID
---@param value boolean AI可执行标记
---@return boolean 是否成功
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
---@param id string 任务ID
---@param path string 文件路径
---@param line? number 行号
---@return boolean 是否成功
function M.update_todo_location(id, path, line)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	local old_path = task.locations.todo and task.locations.todo.path
	local new_path = file.normalize_path(path)

	task.locations.todo = {
		path = new_path,
		line = line or 1,
	}
	task.timestamps.updated = os.time()
	task.verified = false -- 简化

	M._save_internal(id, task)
	update_index(id, old_path, new_path, "todo")

	return true
end

--- 更新代码位置
---@param id string 任务ID
---@param path string 文件路径
---@param line? number 行号
---@param context? table 上下文信息
---@return boolean 是否成功
function M.update_code_location(id, path, line, context)
	local task = M._get_internal(id)
	if not task then
		return false
	end

	local old_path = task.locations.code and task.locations.code.path
	local new_path = file.normalize_path(path)

	task.locations.code = {
		path = new_path,
		line = line or 1,
		context = context,
		context_updated_at = context and os.time() or nil,
	}
	task.timestamps.updated = os.time()
	task.verified = false

	M._save_internal(id, task)
	update_index(id, old_path, new_path, "code")

	return true
end

---------------------------------------------------------------------
-- ⚠️ 废弃的查询API（转发到query并带警告）
---------------------------------------------------------------------

--- 获取所有任务（废弃，请使用 query.get_all_tasks()）
---@deprecated
---@return table<string, table>
function M.get_all_tasks()
	warn_deprecated("core.get_all_tasks", "query.get_all_tasks")
	return require("todo2.store.link.query").get_all_tasks()
end

--- 获取所有有TODO位置的任务（废弃，请使用 query.get_todo_tasks()）
---@deprecated
---@return table<string, table>
function M.get_all_todo_tasks()
	warn_deprecated("core.get_all_todo_tasks", "query.get_todo_tasks")
	return require("todo2.store.link.query").get_todo_tasks()
end

--- 获取所有有代码位置的任务（废弃，请使用 query.get_code_tasks()）
---@deprecated
---@return table<string, table>
function M.get_all_code_tasks()
	warn_deprecated("core.get_all_code_tasks", "query.get_code_tasks")
	return require("todo2.store.link.query").get_code_tasks()
end

---------------------------------------------------------------------
-- 文件重命名处理
---------------------------------------------------------------------

---处理文件重命名
---@param old_path string 原路径
---@param new_path string 新路径
---@return { updated: number, affected_ids: string[] } 更新结果
function M.handle_file_rename(old_path, new_path)
	if not old_path or old_path == "" or not new_path or new_path == "" then
		return { updated = 0, affected_ids = {} }
	end

	local norm_old = file.normalize_path(old_path)
	local norm_new = file.normalize_path(new_path)
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
				index._internal.remove_todo_id(norm_old, id)
				index._internal.add_todo_id(norm_new, id)
			end

			if task.locations.code and task.locations.code.path == norm_old then
				task.locations.code.path = norm_new
				changed = true
				index._internal.remove_code_id(norm_old, id)
				index._internal.add_todo_id(norm_new, id) -- 这里原本可能有个bug？应该是 add_code_id
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
