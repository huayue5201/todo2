-- lua/todo2/store/task/core.lua
-- 任务核心存储模块
-- 负责任务的CRUD操作，确保数据格式正确
---@module "todo2.store.task.core"

local M = {}

local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local file = require("todo2.utils.file")
local line_utils = require("todo2.utils.line")
local locator = require("todo2.code_block.locator")
local code_block_types = require("todo2.code_block.core.types")
local config = require("todo2.config")

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
---@field line_text? string 代码行指纹（去空白后内容），用于定位校验
---@field block_start? number 上次匹配到的代码块起行（1-based）
---@field block_end? number 上次匹配到的代码块终行（1-based）

---@class TaskCore
---@field content string 任务内容
---@field status string 任务状态
---@field previous_status? string 前一个状态

---@class TaskTimestamps
---@field created integer 创建时间戳
---@field updated integer 更新时间戳
---@field completed? integer 完成时间戳
---@field archived? integer 归档时间戳

---@class TaskVerification
---@field needs_relocate boolean 行号是否可能已失效、需要重新定位

---@class Task
---@field id string 任务ID
---@field core TaskCore 核心数据
---@field timestamps TaskTimestamps 时间戳
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
			line_text = loc.line_text,
			block_start = loc.block_start,
			block_end = loc.block_end,
		}
		return code_result
	end

	return result
end

---------------------------------------------------------------------
-- 私有函数：新结构读写
---------------------------------------------------------------------

-- 惰性获取 core.status（它反向依赖本模块，只能运行时再取）
local status_domain_cache
local function get_status_domain()
	if status_domain_cache == nil then
		local ok, mod = pcall(require, "todo2.core.status")
		status_domain_cache = ok and mod or false
	end
	return status_domain_cache or nil
end

---规整行号校验状态。
---needs_relocate = true 表示代码行号可能已失效、需要重新定位。
---早期字段是反义的 line_verified，在读取边界一次性转换（老数据下次保存即清除）。
---@param raw table|nil
---@return TaskVerification
local function normalize_verification(raw)
	raw = raw or {}
	local needs_relocate = raw.needs_relocate
	if needs_relocate == nil then
		-- 缺省视为需要重新定位（与迁移前行为一致）
		needs_relocate = not raw.line_verified
	end
	return { needs_relocate = needs_relocate and true or false }
end

---从新结构加载任务
---@param id string 任务ID
---@return Task|nil
local function load_from_new_layout(id)
	-- 兜底：parser 会为「无 id 的普通任务」产生 id=nil 的节点，
	-- 各 UI 遍历这些节点时会直接把 nil 传进来，这里统一返回 nil 而不是拼串报错。
	if type(id) ~= "string" or id == "" then
		return nil
	end

	local core_data = store.get_key(TASK_PREFIX .. id)
	if not core_data then
		return nil
	end

	local todo_ctx = store.get_key(CTX_PREFIX .. id .. ".todo")
	local code_ctx = store.get_key(CTX_PREFIX .. id .. ".code")

	-- 加载核心数据（浅拷贝并剥离历史冗余字段 id / content_hash / sync_status，
	-- 下次保存即彻底清除）
	local core = vim.tbl_extend("force", {}, core_data.core or {
		content = "",
		status = config.get_default_status(),
	})
	core.id = nil
	core.content_hash = nil
	core.sync_status = nil

	-- 历史遗留状态（normal/urgent/waiting）在读取时规整为当前合法状态，
	-- 下次保存会自然写回。
	local status_domain = get_status_domain()
	if status_domain then
		core.status = status_domain.normalize(core.status)
	end

	---@type Task
	local task = {
		id = id,
		core = core,
		timestamps = core_data.timestamps or { created = 0, updated = 0 },
		verification = normalize_verification(core_data.verification),
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
		core = task.core or {
			content = "",
			status = config.get_default_status(),
		},
		timestamps = task.timestamps or { created = os.time(), updated = os.time() },
		verification = normalize_verification(task.verification),
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

	-- 处理父子关系（关系存于索引命名空间）
	local ok, relation = pcall(require, "todo2.store.task.relation")
	if ok and relation then
		local parent_id = relation.get_parent_id(id)
		if parent_id then
			relation.remove_child(parent_id, id)
		end
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
	-- ⭐ 优先使用传入的 ID（如同步时从文件解析出的 ID），否则生成新 ID
	local id = (type(data.id) == "string" and data.id ~= "") and data.id or id_utils.generate_id()
	local now = os.time()

	---@type Task
	local task = {
		id = id,
		core = {
			content = data.content or "",
			description = data.description,
			status = data.status or config.get_default_status(),
			previous_status = nil,
		},
		timestamps = {
			created = now,
			updated = now,
		},
		-- 锚点元信息（行指纹 / 块范围）尚未采集，首次写入后由重定位补全
		verification = { needs_relocate = true },
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
			context = code_block_types.to_context(data.context),
		}
		index._internal.add_code_id(task.locations.code.path, id)
	end

	save_to_new_layout(id, task)

	-- 设置父子关系
	if data.parent_id then
		local ok, relation_mod = pcall(require, "todo2.store.task.relation")
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

	task.core.content = content
	task.timestamps.updated = os.time()

	save_to_new_layout(id, task)
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
		context = code_block_types.to_context(context),
	}
	task.timestamps.updated = os.time()
	task.verification = task.verification or {}
	task.verification.needs_relocate = true

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

	local task_keys = store.get_namespace_keys("todo.tasks") or {}

	for _, id in ipairs(task_keys) do
		if id and id ~= "" then
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
					task.verification.needs_relocate = true
					save_to_new_layout(id, task)
					table.insert(result.affected_ids, id)
					result.updated = result.updated + 1
				end
			end
		end
	end

	return result
end

---基于存储的代码上下文重新定位代码标记行号
---当代码发生行号变化后，通过匹配上下文中的 signature/name 找回代码块，
---再结合 relative_line 计算标记的新行号。
---@param id string 任务ID
---@param lines_or_path string|string[] 当前文件行数组，或文件路径
---@return boolean 是否成功重定位
--- 查找 text 的出现位置：优先「hint 之上且离 hint 最近」的一次
--- （代码块起点必在任务行之前），上方没有则退而取下方最近的一次。
--- 目的：避免重载/相似签名，或注释、字符串里出现同样片段时命中文件开头那个错误的块。
---@param lines string[]
---@param text string
---@param hint number
---@return number|nil
local function find_nearest_above(lines, text, hint)
	local above, below
	for i, line in ipairs(lines) do
		if line:find(text, 1, true) then
			if i <= hint then
				if not above or i > above then
					above = i
				end
			elseif not below or i < below then
				below = i
			end
		end
	end
	return above or below
end

--- 按行指纹查找；优先取「块范围 [lo, hi] 内」的命中（同一行内容可能全文件多处出现，
--- 如 `return Ok(());`），再在其中取离 hint 最近的一个。
---@param lines string[]
---@param fp string
---@param hint number
---@param lo number|nil 块起始行（1-based）
---@param hi number|nil 块结束行（1-based）
---@return number|nil lnum
---@return boolean unique
local function find_by_fingerprint(lines, fp, hint, lo, hi)
	local all, in_span = {}, {}
	for i, line in ipairs(lines) do
		if line_utils.fingerprint(line) == fp then
			all[#all + 1] = i
			if lo and hi and i >= lo and i <= hi then
				in_span[#in_span + 1] = i
			end
		end
	end

	local pool = (#in_span > 0) and in_span or all
	if #pool == 0 then
		return nil, false
	end
	if #pool == 1 then
		return pool[1], true
	end

	local best, best_dist
	for _, i in ipairs(pool) do
		local d = math.abs(i - hint)
		if not best_dist or d < best_dist then
			best, best_dist = i, d
		end
	end
	return best, false
end

--- 结合代码上下文把标记重新定位到目标行。
---@param id string
---@param lines_or_path string[]|string
---@return boolean
function M.relocate_code_location(id, lines_or_path)
	local task = load_from_new_layout(id)
	if not task or not task.locations or not task.locations.code then
		return false
	end

	local loc = task.locations.code
	local ctx = loc.context
	if not ctx then
		return false
	end

	local lines
	if type(lines_or_path) == "table" then
		lines = lines_or_path
	else
		lines = file.read_lines_smart(loc.path)
	end

	if not lines or #lines == 0 then
		return false
	end

	local signature = ctx.signature
	local name = ctx.name
	local relative = tonumber(ctx.relative_line) or 1
	local anchor = tonumber(loc.line) or 1

	-- ① 结构化查找（treesitter，按 名称+类型）：拿到块的起始与结束行，
	-- 不会命中注释 / 字符串里出现的同名片段。
	local block = locator.pick_block(
		locator.find_blocks({
			path = loc.path,
			lines = lines,
			name = ctx.name,
			block_type = ctx.type,
		}),
		anchor
	)

	local new_start, new_end
	if block then
		new_start, new_end = block.start_line, block.end_line
	else
		-- ② 退化：签名 → 名称 的就近字符串匹配（只知道块起点）
		if signature and signature ~= "" then
			new_start = find_nearest_above(lines, signature, anchor)
		end
		if not new_start and name and name ~= "" then
			new_start = find_nearest_above(lines, name, anchor)
		end
	end

	local fp = loc.line_text
	local verified = true
	local new_line

	if new_start then
		new_line = new_start + relative - 1
		if new_line < 1 then
			new_line = 1
		end
		if new_line > #lines then
			new_line = #lines
		end

		-- ③ 行指纹校验：块起点 + 相对偏移 算出的行，是否确实是同一行？
		-- 不符则按指纹纠正（优先块范围内的命中）；指纹也找不到（行内容已被大改）
		-- 则保留结果但标记为“未验证”，而不是像以前那样无条件信任。
		if fp and fp ~= "" and line_utils.fingerprint(lines[new_line]) ~= fp then
			local fixed, unique = find_by_fingerprint(lines, fp, new_line, new_start, new_end)
			if fixed then
				new_line, verified = fixed, unique
			else
				verified = false
			end
		end
	elseif fp and fp ~= "" then
		-- ④ 最后手段：结构信号全失效时（典型是 context 只有 indent、既无名称也无签名，
		-- 例如标记挂在普通语句行上），用行指纹在全文里定位。
		-- 指纹是最可靠的信号，不该只用于校验；唯一命中才算确认，多处同内容只算“已定位”。
		new_line, verified = find_by_fingerprint(lines, fp, anchor, nil, nil)
	end

	if not new_line then
		return false
	end

	loc.line = new_line
	loc.line_text = line_utils.fingerprint(lines[new_line])
	loc.block_start = new_start
	loc.block_end = new_end
	task.verification = task.verification or {}
	task.verification.needs_relocate = not verified
	task.timestamps = task.timestamps or {}
	task.timestamps.updated = os.time()

	save_to_new_layout(id, task)
	return true
end

return M
