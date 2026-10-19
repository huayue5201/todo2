-- lua/todo2/store/task/core.lua
-- 任务核心存储模块
-- 负责任务的CRUD操作，确保数据格式正确
---@module "todo2.store.task.core"

local M = {}

local index = require("todo2.store.index")
local store = require("todo2.store.nvim_store")
local file = require("todo2.utils.file")
local line_utils = require("todo2.utils.line")
local anchor_utils = require("todo2.utils.anchor")
local locator = require("todo2.code_block.locator")
local code_block_types = require("todo2.code_block.core.types")
local config = require("todo2.config")
local tags_utils = require("todo2.utils.tags")
local namespace = require("todo2.store.namespace")
local anchor_sidecar = require("todo2.store.anchor_sidecar")

-- 命名空间常量
local TASK_PREFIX = namespace.facts.tasks
local CTX_PREFIX = namespace.facts.task_ctx

---------------------------------------------------------------------
-- 类型定义（只定义一次）
---------------------------------------------------------------------

---@class TaskLocation
---@field path string 文件路径
---@field line integer 行号

---@class TaskCodeLocation : TaskLocation
---@field col? integer 锚点列（0-based byte）
---@field end_col? integer 锚点片段结束列（0-based byte，不含）
---@field snippet? string 锚点处的单词片段，用于行内编辑后重新定位列
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

---代码锚点状态：`ok` 已核验；`stale` 位置变动待核验（仍渲染）；`lost` 核验失败、锚点丢失（不渲染）。
---@alias TaskAnchorState
---| '"ok"'
---| '"stale"'
---| '"lost"'

---@class TaskVerification
---@field state TaskAnchorState 代码锚点状态
---@field git? table 锚点失效的 git 归因 { sha, author, date, lost }

---@class TaskGit
---@field commit string 最近一次引用该任务的提交 hash
---@field branch? string 该提交所在分支
---@field author? string 该提交作者
---@field completed? boolean 该引用是否使任务进入终态

---@class Task
---@field id string 任务ID
---@field core TaskCore 核心数据
---@field timestamps TaskTimestamps 时间戳
---@field verification TaskVerification|nil 细粒度验证信息
---@field locations table<string, TaskLocation|TaskCodeLocation> 位置信息
---@field git? TaskGit 关联的 git 元数据

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
			col = tonumber(loc.col),
			end_col = tonumber(loc.end_col),
			snippet = type(loc.snippet) == "string" and loc.snippet ~= "" and loc.snippet or nil,
			context = loc.context,
			line_text = loc.line_text,
			block_start = loc.block_start,
			block_end = loc.block_end,
		}
		if code_result.col ~= nil and code_result.col < 0 then
			code_result.col = 0
		end
		if code_result.col == nil then
			code_result.end_col = nil
			code_result.snippet = nil
		end
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

local ANCHOR_STATES = { ok = true, stale = true, lost = true }

---代码锚点状态常量。
M.ANCHOR = { OK = "ok", STALE = "stale", LOST = "lost" }

---规整代码锚点状态。
---早期数据只有布尔字段（needs_relocate 与反义的 line_verified），
---在读取边界一次性迁移为状态机取值（老数据下次保存即清除）。
---@param raw table|nil
---@return TaskVerification
local function normalize_verification(raw)
	raw = raw or {}
	local state = raw.state
	if not ANCHOR_STATES[state] then
		if raw.lost then
			state = M.ANCHOR.LOST
		elseif raw.needs_relocate == false or raw.line_verified == true then
			state = M.ANCHOR.OK
		else
			state = M.ANCHOR.STALE
		end
	end
	return { state = state, git = raw.git }
end

---读取代码锚点状态（缺省视为待核验）。
---@param task Task|nil
---@return TaskAnchorState
function M.anchor_state(task)
	local v = task and task.verification
	if v and ANCHOR_STATES[v.state] then
		return v.state
	end
	return M.ANCHOR.STALE
end

---代码锚点是否已失联（渲染层应隐藏）。
---@param task Task|nil
---@return boolean
function M.is_anchor_lost(task)
	return M.anchor_state(task) == M.ANCHOR.LOST
end

---设置代码锚点状态。
---@param task Task
---@param state TaskAnchorState
function M.set_anchor_state(task, state)
	task.verification = task.verification or {}
	task.verification.state = state
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

	-- 标签：老任务没有该字段，补空表（标签为多值数组）
	if type(core.tags) ~= "table" then
		core.tags = {}
	end

	local status_domain = get_status_domain()
	if status_domain then
		-- 未知/历史状态在读取时规整为当前合法状态，下次保存会自然写回。
		core.status = status_domain.normalize(core.status)
	end

	---@type Task
	local task = {
		id = id,
		core = core,
		timestamps = core_data.timestamps or { created = 0, updated = 0 },
		verification = normalize_verification(core_data.verification),
		git = core_data.git,
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
		git = task.git,
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
		-- 旁挂一份：store 侧任务记录若被重建/丢失，锚点还能从项目文件恢复
		anchor_sidecar.set(id, code_loc)
	else
		store.delete_key(CTX_PREFIX .. id .. ".code")
		anchor_sidecar.remove(id)
	end
end

---删除新结构中的任务
---@param id string 任务ID
local function delete_new_layout(id)
	store.delete_key(TASK_PREFIX .. id)
	store.delete_key(CTX_PREFIX .. id .. ".todo")
	store.delete_key(CTX_PREFIX .. id .. ".code")
	anchor_sidecar.remove(id)
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

---把任务位置变化同步到文件索引（file_to_todo / file_to_code）。
---索引是「文件 → 任务 id」的倒排表，任务换文件（同步发现的路径漂移、
---重新指定 TODO 链接等）时必须移除旧文件的键、写入新文件的键，
---否则旧文件会残留幽灵索引，且新文件查不到该任务。
---@param id string 任务ID
---@param old_task Task|nil 保存前存储中的任务
---@param new_task Task 待保存的任务
local function reconcile_index(id, old_task, new_task)
	local new_todo = new_task.locations and new_task.locations.todo
	local new_code = new_task.locations and new_task.locations.code
	local old_todo = old_task and old_task.locations and old_task.locations.todo
	local old_code = old_task and old_task.locations and old_task.locations.code

	local new_path = new_todo and new_todo.path
	local old_path = old_todo and old_todo.path
	if new_path then
		index._internal.add_todo_id(new_path, id)
	end
	if old_path and old_path ~= new_path then
		index._internal.remove_todo_id(old_path, id)
	end

	local new_code_path = new_code and new_code.path
	local old_code_path = old_code and old_code.path
	if new_code_path then
		index._internal.add_code_id(new_code_path, id)
	end
	if old_code_path and old_code_path ~= new_code_path then
		index._internal.remove_code_id(old_code_path, id)
	end
end

---保存任务
---@param id string 任务ID
---@param task Task 任务对象
---@return boolean 是否成功
function M.save_task(id, task)
	if not task then
		return false
	end
	-- 保存前读取存储中的旧位置，用于把「换文件」反映到文件索引
	reconcile_index(id, load_from_new_layout(id), task)
	task.timestamps = task.timestamps or {}
	task.timestamps.updated = os.time()
	save_to_new_layout(id, task)
	return true
end

---删除任务
---@param id string 任务ID
---@param opts? { tombstone?: boolean } tombstone=false 用于「可逆移动」
---        （归档、孤儿隔离），这类删除不写删除墓碑；默认写墓碑，
---        防止已删任务被文件同步 / 归档反归档 / 孤儿还原 / 迁移悄悄复活。
---@return boolean 是否成功
function M.delete_task(id, opts)
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
		-- 解除子任务对已删除任务的引用，避免留下悬空 parent。
		-- 遍历副本：remove_child 会原地修改 store 返回值（同一表引用），
		-- 直接遍历会跳过元素、留下悬空关系。
		for _, child_id in ipairs(vim.deepcopy(relation.get_child_ids(id))) do
			relation.remove_child(id, child_id)
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

	-- 写删除墓碑（默认开启）。放在最后：只有真正删成功才标记。
	if not opts or opts.tombstone ~= false then
		local ok, tombstone = pcall(require, "todo2.store.tombstone")
		if ok and tombstone then
			tombstone.mark(id, "delete")
		end
	end

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

	-- 文件即真源：任务被重建（例如用户在缓冲区撤销删除）时清除历史删除墓碑，
	-- 维持「任务存在 ⇒ 无删除墓碑」。墓碑只用于拦截 store 侧的还原通道。
	local ok_ts, tombstone = pcall(require, "todo2.store.tombstone")
	if ok_ts and tombstone and tombstone.is_deleted(id) then
		tombstone.clear(id)
	end

	---@type Task
	local task = {
		id = id,
		core = {
			content = data.content or "",
			description = data.description,
			status = data.status or config.get_default_status(),
			previous_status = nil,
			tags = tags_utils.normalize(data.tags),
		},
		timestamps = {
			created = now,
			updated = now,
		},
		-- 锚点元信息（行指纹 / 块范围）尚未采集，首次写入后由重定位补全
		verification = { state = M.ANCHOR.STALE },
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

---设置任务标签（整体替换）
---@param id string 任务ID
---@param tags string[]|nil 新标签列表
---@return boolean 是否成功
function M.set_tags(id, tags)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end

	task.core.tags = tags_utils.normalize(tags)
	task.timestamps.updated = os.time()

	save_to_new_layout(id, task)
	return true
end

---记录任务关联的 git 元数据（最近一次引用它的提交）；不触碰 updated，避免打乱排序。
---@param id string
---@param data TaskGit
---@return boolean 是否成功
function M.set_git(id, data)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end
	task.git = vim.tbl_extend("force", task.git or {}, data)
	save_to_new_layout(id, task)
	return true
end

---记录锚点失效的 git 归因（最近一次改变该代码的提交）；不改变锚点状态、不触碰 updated。
---@param id string
---@param data? table { sha, author, date, lost }
---@return boolean 是否成功
function M.set_anchor_git(id, data)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end
	task.verification = task.verification or {}
	task.verification.git = data
	save_to_new_layout(id, task)
	return true
end

---添加标签（并集）
---@param id string 任务ID
---@param tags string[]|nil 要添加的标签
---@return boolean 是否成功
function M.add_tags(id, tags)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end

	local merged = vim.deepcopy(task.core.tags or {})
	vim.list_extend(merged, tags_utils.normalize(tags))
	task.core.tags = tags_utils.normalize(merged)
	task.timestamps.updated = os.time()

	save_to_new_layout(id, task)
	return true
end

---移除标签
---@param id string 任务ID
---@param tags string[]|nil 要移除的标签
---@return boolean 是否成功
function M.remove_tags(id, tags)
	local task = load_from_new_layout(id)
	if not task then
		return false
	end

	local remove = {}
	for _, t in ipairs(tags_utils.normalize(tags)) do
		remove[t] = true
	end

	local kept = {}
	for _, t in ipairs(task.core.tags or {}) do
		if not remove[t] then
			kept[#kept + 1] = t
		end
	end

	task.core.tags = tags_utils.normalize(kept)
	task.timestamps.updated = os.time()

	save_to_new_layout(id, task)
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

	local task_keys = store.get_namespace_keys(namespace.facts.tasks_ns) or {}

	for _, id in ipairs(task_keys) do
		if id and id ~= "" then
			local task = load_from_new_layout(id)
			if task and task.locations then
				local changed = false

				if task.locations.todo and task.locations.todo.path == norm_old then
					task.locations.todo.path = norm_new
					changed = true
				end

				if task.locations.code and task.locations.code.path == norm_old then
					task.locations.code.path = norm_new
					changed = true
				end

				if changed then
					M.set_anchor_state(task, M.ANCHOR.STALE)
					-- save_task 会按新旧位置差异更新 file_to_todo / file_to_code
					M.save_task(id, task)
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

	task.timestamps = task.timestamps or {}
	task.timestamps.updated = os.time()

	if not new_line then
		-- 结构信号与行指纹都找不到锚点：判定失联，由渲染层隐藏并在 TODO 行提示。
		M.set_anchor_state(task, M.ANCHOR.LOST)
		save_to_new_layout(id, task)
		return false
	end

	loc.line = new_line
	loc.line_text = line_utils.fingerprint(lines[new_line])
	loc.block_start = new_start
	loc.block_end = new_end

	-- 列是软提示：优先按片段在（可能已变化的）行内重新定位，找不到则夹紧旧列。
	if loc.col ~= nil then
		loc.col, loc.end_col = anchor_utils.refine(lines[new_line], loc.col, loc.end_col, loc.snippet)
	end

	M.set_anchor_state(task, verified and M.ANCHOR.OK or M.ANCHOR.STALE)

	save_to_new_layout(id, task)
	return true
end

return M
