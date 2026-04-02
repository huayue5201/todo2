-- lua/todo2/store/link/core.lua
-- 任务核心存储模块
-- 负责任务的CRUD操作，确保数据格式正确
---@module "todo2.store.link.core"

local M = {}

local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local file = require("todo2.utils.file")

-- 命名空间常量
local TASK_PREFIX = "todo.tasks."
local CTX_PREFIX = "todo.task_ctx."

---------------------------------------------------------------------
-- 类型定义（只定义一次）
---------------------------------------------------------------------

---@class TaskLocation
---@field path string 文件路径
---@field line integer 行号

---@class TaskCodeLocation : TaskLocation
---@field context? table 代码上下文
---@field context_updated_at? integer 上下文更新时间戳

---@class TaskCore
---@field id string 任务ID
---@field content string 任务内容
---@field status string 任务状态
---@field previous_status? string 前一个状态
---@field content_hash string 内容哈希
---@field tags string[] 标签列表
---@field ai_executable? boolean 是否可AI执行
---@field sync_status string 同步状态

---@class TaskRelations
---@field parent_id? string 父任务ID

---@class TaskTimestamps
---@field created integer 创建时间戳
---@field updated integer 更新时间戳
---@field completed? integer 完成时间戳
---@field archived? integer 归档时间戳

---@class TaskVerification
---@field line_verified boolean 是否已验证行号
---@field last_verified_at? integer 最后验证时间戳

---@class Task
---@field id string 任务ID
---@field core TaskCore 核心数据
---@field relations? TaskRelations 关系数据
---@field timestamps TaskTimestamps 时间戳
---@field verified boolean 是否已验证（旧字段，保留兼容）
---@field verification TaskVerification|nil 细粒度验证信息
---@field locations table<string, TaskLocation|TaskCodeLocation> 位置信息

---------------------------------------------------------------------
-- 私有函数：数据格式验证
---------------------------------------------------------------------

---验证并修复位置数据
---@param loc any 原始位置数据
---@param is_code boolean 是否为代码位置
---@return TaskLocation|TaskCodeLocation|nil
local function validate_location(loc, is_code)
	if not loc or type(loc) ~= "table" then
		return nil
	end

	-- 处理旧结构：{ id = "xxx", line = 10 }
	-- 这里历史上可能用 id 表示路径，但现在无法可靠恢复，只做最小兼容
	if loc.id and not loc.path then
		-- 保留原结构，不做强制转换，避免误写
		loc.path = loc.path or ""
	end

	-- 验证必要字段
	if type(loc.path) ~= "string" then
		return nil
	end

	local line = tonumber(loc.line)
	-- 行号不合法时，尽量修正为 1，而不是直接丢弃位置
	if not line or line < 1 then
		line = 1
	end

	---@type TaskLocation
	local result = {
		path = file.normalize_path(loc.path),
		line = line,
	}

	if is_code then
		---@type TaskCodeLocation
		local code_result = {
			path = file.normalize_path(loc.path),
			line = line,
			context = loc.context,
			context_updated_at = type(loc.context_updated_at) == "number" and loc.context_updated_at or nil,
		}
		return code_result
	end

	return result
end

---------------------------------------------------------------------
-- 私有函数：新结构读写
---------------------------------------------------------------------

---从新结构加载任务
---@param id string 任务ID
---@return Task|nil
local function load_from_new_layout(id)
	local core_data = store.get_key(TASK_PREFIX .. id)
	if not core_data then
		return nil
	end

	local todo_ctx = store.get_key(CTX_PREFIX .. id .. ".todo")
	local code_ctx = store.get_key(CTX_PREFIX .. id .. ".code")

	---@type Task
	local task = {
		id = id,
		core = core_data.core or {
			id = id,
			content = "",
			status = "normal",
			content_hash = "",
			tags = {},
			sync_status = "local",
		},
		relations = core_data.relations,
		timestamps = core_data.timestamps or { created = 0, updated = 0 },
		verified = core_data.verified == true,
		verification = core_data.verification or { line_verified = false },
		locations = {},
	}

	-- 验证并设置位置数据
	if todo_ctx then
		local todo_loc = validate_location(todo_ctx, false)
		if todo_loc then
			task.locations.todo = todo_loc
		end
	end

	if code_ctx then
		local code_loc = validate_location(code_ctx, true)
		if code_loc then
			task.locations.code = code_loc
		end
	end

	return task
end

---保存任务到新结构
---@param id string 任务ID
---@param task Task 任务对象
local function save_to_new_layout(id, task)
	if not task then
		return
	end

	-- 验证并修复位置数据
	local todo_loc = task.locations and validate_location(task.locations.todo, false)
	local code_loc = task.locations and validate_location(task.locations.code, true)

	---@type table
	local core_data = {
		id = task.id or id,
		core = task.core or {
			id = id,
			content = "",
			status = "normal",
			content_hash = "",
			tags = {},
			sync_status = "local",
		},
		relations = task.relations,
		timestamps = task.timestamps or { created = os.time(), updated = os.time() },
		verified = task.verified == true,
		verification = task.verification,
	}

	store.set_key(TASK_PREFIX .. id, core_data)

	-- 保存位置数据
	if todo_loc then
		store.set_key(CTX_PREFIX .. id .. ".todo", todo_loc)
	else
		store.delete_key(CTX_PREFIX .. id .. ".todo")
	end

	if code_loc then
		store.set_key(CTX_PREFIX .. id .. ".code", code_loc)
	else
		store.delete_key(CTX_PREFIX .. id .. ".code")
	end
end

---删除新结构中的任务
---@param id string 任务ID
local function delete_new_layout(id)
	store.delete_key(TASK_PREFIX .. id)
	store.delete_key(CTX_PREFIX .. id .. ".todo")
	store.delete_key(CTX_PREFIX .. id .. ".code")
end

---------------------------------------------------------------------
-- 索引更新
---------------------------------------------------------------------

---更新文件索引
---@param id string 任务ID
---@param old_path string|nil 旧路径
---@param new_path string|nil 新路径
---@param loc_type "todo"|"code" 位置类型
local function update_index(id, old_path, new_path, loc_type)
	if old_path == new_path then
		return
	end

	if old_path then
		if loc_type == "todo" then
			index._internal.remove_todo_id(old_path, id)
		else
			index._internal.remove_code_id(old_path, id)
		end
	end

	if new_path then
		if loc_type == "todo" then
			index._internal.add_todo_id(new_path, id)
		else
			index._internal.add_code_id(new_path, id)
		end
	end
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

---获取任务
---@param id string 任务ID
---@return Task|nil
function M.get_task(id)
	return load_from_new_layout(id)
end

---获取任务在TODO文件中的位置
---@param id string 任务ID
---@return TaskLocation|nil
function M.get_todo_location(id)
	local task = load_from_new_layout(id)
	if not task or not task.locations then
		return nil
	end
	return task.locations.todo
end

---获取任务在代码文件中的位置
---@param id string 任务ID
---@return TaskCodeLocation|nil
function M.get_code_location(id)
	local task = load_from_new_layout(id)
	if not task or not task.locations then
		return nil
	end
	local code_loc = task.locations.code
	if code_loc and code_loc.path and code_loc.line then
		return code_loc ---@type TaskCodeLocation
	end
	return nil
end

---保存任务
---@param id string 任务ID
---@param task Task 任务对象
---@return boolean 是否成功
function M.save_task(id, task)
	if not task then
		return false
	end
	task.timestamps = task.timestamps or {}
	task.timestamps.updated = os.time()
	task.verification = task.verification or { line_verified = false }
	save_to_new_layout(id, task)
	return true
end

---删除任务
---@param id string 任务ID
---@return boolean 是否成功
function M.delete_task(id)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end

	-- 处理父子关系
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if ok and relation and task.relations and task.relations.parent_id then
		relation.remove_child(task.relations.parent_id, id)
	end

	-- 更新索引
	if task.locations then
		if task.locations.todo then
			index._internal.remove_todo_id(task.locations.todo.path, id)
		end
		if task.locations.code then
			index._internal.remove_code_id(task.locations.code.path, id)
		end
	end

	delete_new_layout(id)
	return true
end

---创建任务
---@param data table 任务数据
---@return string 任务ID
function M.create_task(data)
	local id_utils = require("todo2.utils.id")
	local id = id_utils.generate_id()
	local now = os.time()
	local hash = require("todo2.utils.hash").hash

	---@type Task
	local task = {
		id = id,
		core = {
			id = id,
			content = data.content or "",
			status = data.status or types.STATUS.NORMAL,
			previous_status = nil,
			content_hash = hash(data.content or ""),
			tags = data.tags or { "TODO" },
			ai_executable = data.ai_executable,
			sync_status = "local",
		},
		relations = data.parent_id and { parent_id = data.parent_id } or nil,
		timestamps = {
			created = now,
			updated = now,
		},
		verified = true,
		verification = { line_verified = false },
		locations = {},
	}

	-- 设置TODO位置
	if data.todo_path then
		local line = tonumber(data.todo_line) or 1
		if line < 1 then
			line = 1
		end
		task.locations.todo = {
			path = file.normalize_path(data.todo_path),
			line = line,
		}
		index._internal.add_todo_id(task.locations.todo.path, id)
	end

	-- 设置代码位置
	if data.code_path then
		local line = tonumber(data.code_line) or 1
		if line < 1 then
			line = 1
		end
		task.locations.code = {
			path = file.normalize_path(data.code_path),
			line = line,
			context = data.context,
			context_updated_at = data.context and now or nil,
		}
		index._internal.add_code_id(task.locations.code.path, id)
	end

	save_to_new_layout(id, task)

	-- 设置父子关系
	if data.parent_id then
		local ok, relation_mod = pcall(require, "todo2.store.link.relation")
		if ok and relation_mod and relation_mod.set_parent_child then
			relation_mod.set_parent_child(data.parent_id, id)
		end
	end

	return id
end

---更新任务内容
---@param id string 任务ID
---@param content string 新内容
---@return boolean 是否成功
function M.update_content(id, content)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end

	local hash = require("todo2.utils.hash").hash
	task.core.content = content
	task.core.content_hash = hash(content)
	task.timestamps.updated = os.time()

	save_to_new_layout(id, task)
	return true
end

---更新任务状态
---@param id string 任务ID
---@param status string 新状态
---@return boolean 是否成功
function M.update_status(id, status)
	local task = load_from_new_layout(id)
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

	save_to_new_layout(id, task)
	return true
end

---更新任务标签
---@param id string 任务ID
---@param tags string[] 新标签列表
---@return boolean 是否成功
function M.update_tags(id, tags)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end

	task.core.tags = tags
	task.timestamps.updated = os.time()

	save_to_new_layout(id, task)
	return true
end

---更新AI可执行标记
---@param id string 任务ID
---@param value boolean 新值
---@return boolean 是否成功
function M.update_ai_executable(id, value)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end

	task.core.ai_executable = value
	task.timestamps.updated = os.time()

	save_to_new_layout(id, task)
	return true
end

---更新TODO位置
---@param id string 任务ID
---@param path string 文件路径
---@param line integer|string 行号
---@return boolean 是否成功
function M.update_todo_location(id, path, line)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end

	local line_num = tonumber(line)
	if not line_num or line_num < 1 then
		line_num = 1
	end

	task.locations = task.locations or {}
	local old_path = task.locations.todo and task.locations.todo.path
	local new_path = file.normalize_path(path)

	task.locations.todo = {
		path = new_path,
		line = line_num,
	}
	task.timestamps.updated = os.time()
	task.verified = false
	task.verification = task.verification or {}
	task.verification.line_verified = false

	save_to_new_layout(id, task)
	update_index(id, old_path, new_path, "todo")

	return true
end

---更新代码位置
---@param id string 任务ID
---@param path string 文件路径
---@param line integer|string 行号
---@param context? table 代码上下文
---@return boolean 是否成功
function M.update_code_location(id, path, line, context)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end

	local line_num = tonumber(line)
	if not line_num or line_num < 1 then
		line_num = 1
	end

	task.locations = task.locations or {}
	local old_path = task.locations.code and task.locations.code.path
	local new_path = file.normalize_path(path)

	task.locations.code = {
		path = new_path,
		line = line_num,
		context = context,
		context_updated_at = context and os.time() or nil,
	}
	task.timestamps.updated = os.time()
	task.verified = false
	task.verification = task.verification or {}
	task.verification.line_verified = false

	save_to_new_layout(id, task)
	update_index(id, old_path, new_path, "code")

	return true
end

---处理文件重命名
---@param old_path string 原路径
---@param new_path string 新路径
---@return table 处理结果 { updated = number, affected_ids = string[] }
function M.handle_file_rename(old_path, new_path)
	local result = { updated = 0, affected_ids = {} }

	if not old_path or old_path == "" or not new_path or new_path == "" then
		return result
	end

	local norm_old = file.normalize_path(old_path)
	local norm_new = file.normalize_path(new_path)
	if norm_old == norm_new then
		return result
	end

	local task_keys = store.get_namespace_keys(TASK_PREFIX) or {}

	for _, key in ipairs(task_keys) do
		local id = key:match("^" .. TASK_PREFIX .. "(.*)$")
		if id then
			local task = load_from_new_layout(id)
			if task and task.locations then
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
					index._internal.add_code_id(norm_new, id)
				end

				if changed then
					task.timestamps.updated = os.time()
					task.verification = task.verification or {}
					task.verification.line_verified = false
					save_to_new_layout(id, task)
					table.insert(result.affected_ids, id)
					result.updated = result.updated + 1
				end
			end
		end
	end

	return result
end

---验证并更新行号
---@param id string 任务ID
---@param file_path string 文件路径
---@param line_num integer 当前行号
---@return boolean 是否成功验证
function M.verify_and_update_line(id, file_path, line_num)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end

	task.locations = task.locations or {}
	task.locations.todo = task.locations.todo or {}

	local stored_line = task.locations.todo.line
	local stored_file = task.locations.todo.path

	if not stored_line then
		task.locations.todo.line = line_num
		task.locations.todo.path = file_path
		task.verified = true
		task.verification = task.verification or {}
		task.verification.line_verified = true
		task.verification.last_verified_at = os.time()
		save_to_new_layout(id, task)
		return true
	end

	if stored_file ~= file_path then
		task.locations.todo.line = line_num
		task.locations.todo.path = file_path
		task.verified = true
		task.verification = task.verification or {}
		task.verification.line_verified = true
		task.verification.last_verified_at = os.time()
		save_to_new_layout(id, task)
		return true
	end

	if stored_file == file_path then
		if stored_line == line_num then
			if not task.verified or not (task.verification and task.verification.line_verified) then
				task.verified = true
				task.verification = task.verification or {}
				task.verification.line_verified = true
				task.verification.last_verified_at = os.time()
				save_to_new_layout(id, task)
			end
			return true
		end

		-- 尝试通过内容匹配找到正确行号
		local lines = vim.fn.readfile(file_path)
		local content = task.core and task.core.content or ""

		if content ~= "" then
			for i, content_line in ipairs(lines) do
				if content_line:find(content, 1, true) then
					task.locations.todo.line = i
					task.locations.todo.path = file_path
					task.verified = true
					task.verification = task.verification or {}
					task.verification.line_verified = true
					task.verification.last_verified_at = os.time()
					save_to_new_layout(id, task)
					return true
				end
			end
		end
	end

	return false
end

---获取权威行号
---@param id string 任务ID
---@param default_line integer 默认行号
---@return integer
function M.get_authoritative_line(id, default_line)
	local task = load_from_new_layout(id)
	if not task or not task.locations or not task.locations.todo then
		return default_line
	end
	return task.locations.todo.line or default_line
end

return M

