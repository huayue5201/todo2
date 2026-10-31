-- lua/todo2/store/schema.lua
-- 存储数据形状契约：facts.* 读写边界的唯一归一化入口。
--
-- 为什么需要它（而不是一个迁移框架）：
--   * 本插件的真源是磁盘上的 *.todo.md，任何「文件派生」的数据丢了都能由
--     reconcile 重建，所以历史做法是硬切旧命名空间（namespace.purge_legacy）。
--   * 真正需要照顾的是 facts.* 里**不可重建**的那部分：timestamps、删除墓碑、
--     孤儿快照、代码锚点校验状态。它们的兼容逻辑原先散落在 core.lua 的读取
--     路径里（剥历史字段、补默认值、丢弃非法值），每加一个字段就要在好几处
--     记得补默认值——散落本身才是 bug 源。
--   * 因此这里只做两件事：① 记录这份数据是哪个形状版本写的（只标记，不转换）；
--     ② 把所有「老数据 → 当前形状」的适配收敛到一个函数。
--
-- 不做的事：不写迁移器、不改用户文件、不猜语义。遇到无法安全归一的字段就丢掉
-- 并留下可诊断的返回信息，等下一次真源重建。
---@module "todo2.store.schema"

local M = {}

local config = require("todo2.config")
local due_utils = require("todo2.utils.due")
local file = require("todo2.utils.file")

---------------------------------------------------------------------
-- 形状版本
--
-- 只在「新增字段 / 新增键」时保持不变——那些由 normalize_* 的默认值即可吸收。
-- 需要 +1 的是**不兼容变更**：改键名、改语义（时间戳单位、fingerprint 算法）、
-- 字典集合 split/merge、删除字段。真正的数据转换请参考 README 的迁移判据表。
---------------------------------------------------------------------
M.VERSION = 3

---形状版本所在的 facts 键（与 namespace.facts 并列，单独放一处）
M.VERSION_KEY = "facts.meta.schema_version"

---------------------------------------------------------------------
-- 契约：Task 的必需字段
--
-- test/schema.lua 会按这张表断言 normalize_task 的输出——给 Task 加字段时，
-- 要么加进必需表并在 normalize_task 里给默认值，要么明确写进注释说明可选，
-- 否则测试就红。这是防止「新字段在某些读取路径上悄悄是 nil」的护栏。
---------------------------------------------------------------------

---@type table<string, string[]>
M.TASK_CONTRACT = {
	root = { "id", "core", "timestamps", "verification", "locations" },
	-- core_optional 里的字段允许缺省（nil = 没有该时间维度）
	core = { "content", "status", "tags" },
	core_optional = { "start", "due", "pinned" },
	-- content_updated 记录「内容/锚点最后一次变化」，日历活动层用它；
	-- 改到期/标签只动 updated，所以不会把任务挪到今天的活动格。
	timestamps = { "created", "updated" },
	timestamps_optional = { "content_updated", "completed", "archived" },
	verification = { "state" },
}

---代码锚点状态（与 core.M.ANCHOR 同源，避免两处字面量漂移）
M.ANCHOR = { OK = "ok", STALE = "stale", LOST = "lost" }

local ANCHOR_STATES = { ok = true, stale = true, lost = true }

---------------------------------------------------------------------
-- 依赖（status 反向依赖 store，只能运行时再取；取不到就跳过归一）
---------------------------------------------------------------------

local status_domain_cache
local function get_status_domain()
	if status_domain_cache == nil then
		local ok, mod = pcall(require, "todo2.core.status")
		status_domain_cache = ok and mod or false
	end
	return status_domain_cache or nil
end

local function default_status()
	local domain = get_status_domain()
	if domain and domain.default then
		return domain.default
	end
	return config.get_default_status()
end

---------------------------------------------------------------------
-- 位置
---------------------------------------------------------------------

---验证并修复位置数据
---@param loc any 原始位置数据
---@param is_code boolean 是否为代码位置
---@return TaskLocation|TaskCodeLocation|nil
function M.validate_location(loc, is_code)
	if not loc or type(loc) ~= "table" then
		return nil
	end

	if type(loc.path) ~= "string" then
		return nil
	end

	local line = tonumber(loc.line)
	-- 行号不合法时，尽量修正为 1，而不是直接丢弃位置
	if not line or line < 1 then
		line = 1
	end

	if not is_code then
		return {
			path = file.normalize_path(loc.path),
			line = line,
		}
	end

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

---归一化一组位置（todo / code）
---@param raw table|nil { todo = <raw>, code = <raw> }
---@return table<string, TaskLocation|TaskCodeLocation>
local function normalize_locations(raw)
	local out = {}
	raw = type(raw) == "table" and raw or {}
	for _, key in ipairs({ "todo", "code" }) do
		local loc = raw[key]
		if loc ~= nil then
			local validated = M.validate_location(loc, key == "code")
			if validated then
				out[key] = validated
			end
		end
	end
	return out
end

---------------------------------------------------------------------
-- 锚点校验状态
---------------------------------------------------------------------

---规整代码锚点状态。
---早期数据只有布尔字段（needs_relocate 与反义的 line_verified），
---在读取边界一次性迁移为状态机取值（老数据下次保存即清除）。
---@param raw table|nil
---@return TaskVerification
function M.normalize_verification(raw)
	raw = type(raw) == "table" and raw or {}
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
	return { state = state, git = type(raw.git) == "table" and raw.git or nil }
end

---------------------------------------------------------------------
-- 任务
---------------------------------------------------------------------

---归一化标签数组（非字符串/空串元素直接丢弃）
---@param raw any
---@return string[]
local function normalize_tags(raw)
	if type(raw) ~= "table" then
		return {}
	end
	local out = {}
	for _, tag in ipairs(raw) do
		if type(tag) == "string" and tag ~= "" then
			out[#out + 1] = tag
		end
	end
	return out
end

---归一化时间戳（缺失保持 0 —— 不伪造真实时间）
---@param raw any
---@return TaskTimestamps
local function normalize_timestamps(raw)
	raw = type(raw) == "table" and raw or {}
	local ts = {
		created = tonumber(raw.created) or 0,
		updated = tonumber(raw.updated) or 0,
	}
	local content_updated = tonumber(raw.content_updated)
	if content_updated then
		ts.content_updated = content_updated
	end
	local completed = tonumber(raw.completed)
	local archived = tonumber(raw.archived)
	if completed then
		ts.completed = completed
	end
	if archived then
		ts.archived = archived
	end
	return ts
end

---把任意历史形状的任务数据归一成当前 Task 契约。
---
---接受两种输入形状（store 记录 / 孤儿快照里的 Task），因为两者字段集是包含关系：
---   * store 记录：{ core, timestamps, verification, git } + 位置在别的键里
---   * Task 对象：{ id, core, timestamps, verification, git, locations }
---@param record any 原始记录
---@param id? string 任务 ID（缺省取 record.id）
---@param raw_locations? table { todo = <raw>, code = <raw> }
---@return Task
function M.normalize_task(record, id, raw_locations)
	record = type(record) == "table" and record or {}

	-- 核心数据：浅拷贝后剥离历史冗余字段（下次保存即彻底清除）
	local core = vim.tbl_extend("force", {}, type(record.core) == "table" and record.core or {})
	core.id = nil
	core.content_hash = nil
	core.sync_status = nil
	core.content = type(core.content) == "string" and core.content or tostring(core.content or "")
	core.tags = normalize_tags(core.tags)

	local domain = get_status_domain()
	if domain then
		-- 未知/历史状态在读取时规整为当前合法状态，下次保存会自然写回。
		core.status = domain.normalize(core.status)
	end
	if core.status == nil or core.status == "" then
		core.status = default_status()
	end

	-- 到期日：历史脏数据（非法日期）直接丢弃，避免坏值参与排序/筛选
	if core.due ~= nil and not due_utils.is_date(core.due) then
		core.due = nil
	end
	-- 开始日：同理丢弃非法值；`start > due` 视为脏数据（区间不成立）
	-- 只保留 due，避免渲染出倒置的区间
	if core.start ~= nil and not due_utils.is_date(core.start) then
		core.start = nil
	end
	if core.start ~= nil and core.due ~= nil and core.start > core.due then
		core.start = nil
	end
	if core.previous_status ~= nil and type(core.previous_status) ~= "string" then
		core.previous_status = nil
	end
	-- 搁置是布尔收纳位：任何非 true 的值都当「未搁置」，避免历史脏数据留下来
	if core.pinned ~= true then
		core.pinned = nil
	end

	---@type Task
	local task = {
		id = id or record.id,
		core = core,
		timestamps = normalize_timestamps(record.timestamps),
		verification = M.normalize_verification(record.verification),
		locations = normalize_locations(raw_locations or record.locations),
	}
	if type(record.git) == "table" then
		task.git = record.git
	end
	return task
end

---------------------------------------------------------------------
-- 字典型 facts（不从任务读取路径经过的集合）
---------------------------------------------------------------------

---墓碑记录归一：{ deleted_at = number, reason = string }
---@param raw any
---@return table|nil
local function normalize_tombstone(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local at = tonumber(raw.deleted_at)
	if not at or at <= 0 then
		return nil
	end
	return {
		deleted_at = at,
		reason = type(raw.reason) == "string" and raw.reason ~= "" and raw.reason or "delete",
	}
end

---孤儿记录归一：{ task = Task, parent?, children, orphaned_at }
---@param raw any
---@param id? string
---@return table|nil
local function normalize_orphan(raw, id)
	if type(raw) ~= "table" or type(raw.task) ~= "table" then
		return nil
	end
	local task = M.normalize_task(raw.task, id or raw.task.id)
	local children = {}
	if type(raw.children) == "table" then
		for _, child in ipairs(raw.children) do
			if type(child) == "string" and child ~= "" then
				children[#children + 1] = child
			end
		end
	end
	return {
		task = task,
		parent = type(raw.parent) == "string" and raw.parent ~= "" and raw.parent or nil,
		children = children,
		orphaned_at = tonumber(raw.orphaned_at) or os.time(),
	}
end

---按完整键名归一 facts 值。
---
---认识的键返回修复后的值；值不可用时返回 nil（调用方应视同不存在，不要带病使用）；
---不认识的键原样返回（新增 facts 键无需在这里登记）。
---@param key string 完整 store 键
---@param value any 原始值
---@return any value|nil, string|nil reason
function M.normalize_facts(key, value)
	if type(key) ~= "string" then
		return value
	end

	if key:sub(1, #"facts.deleted.") == "facts.deleted." then
		local fixed = normalize_tombstone(value)
		if not fixed then
			return nil, "tombstone record is not usable"
		end
		return fixed
	end

	if key:sub(1, #"facts.orphan.") == "facts.orphan." then
		local id = key:sub(#"facts.orphan." + 1)
		local fixed = normalize_orphan(value, id)
		if not fixed then
			return nil, "orphan record has no task snapshot"
		end
		return fixed
	end

	return value
end

---------------------------------------------------------------------
-- 版本标记
---------------------------------------------------------------------

---读取当前数据形状版本（老库没有该键时返回 nil）
---@return integer|nil
function M.read_version()
	local store = require("todo2.store.nvim_store")
	local v = store.get_key(M.VERSION_KEY)
	if type(v) == "table" then
		v = v.version
	end
	return tonumber(v)
end

---把数据形状版本写成当前代码的版本。
---
---只做标记，**不做数据转换**：转换由 normalize_* 在读取边界逐条完成，
---所以即使版本落后也不影响正确性，标记的意义是让未来的不兼容变更能发现老数据。
---@return { from: integer|nil, to: integer }
function M.stamp()
	local store = require("todo2.store.nvim_store")
	local from = M.read_version()
	if from ~= M.VERSION then
		store.set_key(M.VERSION_KEY, M.VERSION)
	end
	return { from = from, to = M.VERSION }
end

return M
