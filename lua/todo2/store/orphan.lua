-- lua/todo2/store/orphan.lua
-- 孤儿任务回收：TODO 文件（或唯一代码锚点文件）在插件之外被删除后，
-- 任务会失去全部存活位置。此时先把任务「隔离」到独立桶 todo.orphan.<id>
-- （数据完整保留、从活跃视图隐藏），保留期内文件恢复则自动还原，
-- 超期仍缺失才真正清除。绝不因为一次 stat 失败就丢数据。
---@module "todo2.store.orphan"

local M = {}

local config = require("todo2.config")
local store = require("todo2.store.nvim_store")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local tombstone = require("todo2.store.tombstone")
local id_utils = require("todo2.utils.id")
local namespace = require("todo2.store.namespace")

---隔离桶键前缀：todo.orphan.<id> = { task, parent, children, orphaned_at }
local ORPHAN_PREFIX = namespace.facts.orphan
---@type string 读取用的命名空间（namespace_keys 会自动补点）
local ORPHAN_NS = namespace.facts.orphan_ns

local SECONDS_PER_DAY = 86400

---------------------------------------------------------------------
-- 位置存活判定
---------------------------------------------------------------------

--- 构造一对带缓存的文件探针：exists / contains。
--- 一次 sweep 内同一路径只 stat/读取一次，避免逐任务重复读盘。
---
--- 关键：文件存在 ≠ 位置存活。TODO 任务行可能已从文件里被删掉
--- （这正是幽灵任务一直判活的根因），因此 TODO 位置必须用 contains 确认
--- 该 id 仍在；代码锚点不写入标记行（见 creation/service.create_code_link），
--- 故代码位置只能用 exists 判定。
---
--- 只有 ENOENT 才算缺失；stat/读取异常（非 ENOENT）视为「无法确认」，
--- 一律按「仍存在」保守处理，绝不误判为孤儿。
---@return fun(path: string|nil): boolean, fun(path: string|nil, id: string): boolean
local function make_file_probe()
	local cache = {}

	local function load(path)
		local entry = cache[path]
		if entry then
			return entry
		end
		local stat, _, errname = vim.loop.fs_stat(path)
		if not stat then
			entry = { state = errname == "ENOENT" and "missing" or "unknown" }
		else
			local ok, lines = pcall(vim.fn.readfile, path)
			if not ok or not lines then
				entry = { state = "unknown" }
			else
				entry = { state = "present", lines = lines }
			end
		end
		cache[path] = entry
		return entry
	end

	--- 路径是否存在（unknown 保守视为存在）。
	local function exists(path)
		if not path or path == "" then
			return false
		end
		return load(path).state ~= "missing"
	end

	--- 文件内容是否仍含该 id 标记（unknown 保守视为含）。
	local function contains(path, id)
		if not path or path == "" or not id then
			return false
		end
		local entry = load(path)
		if entry.state == "unknown" then
			return true
		end
		if entry.state == "missing" then
			return false
		end
		local frontier = "%f[%w]" .. vim.pesc(id) .. "%f[%W]"
		for _, line in ipairs(entry.lines) do
			if id_utils.extract_id_from_line(line) == id or line:find(frontier) then
				return true
			end
		end
		return false
	end

	return exists, contains
end

--- 任务是否有任一存活位置。
--- TODO 位置要求文件存在且仍含该 id；代码位置只要求文件存在。
--- 无任何位置信息的任务保守视为存活，绝不隔离。
---@param task Task|nil
---@param exists fun(path: string|nil): boolean
---@param contains fun(path: string|nil, id: string): boolean
---@return boolean
local function task_live(task, exists, contains)
	local locs = (task and task.locations) or {}
	local todo = locs.todo and locs.todo.path
	local code = locs.code and locs.code.path
	if not todo and not code then
		return true
	end
	if todo and contains(todo, task.id) then
		return true
	end
	if code and exists(code) then
		return true
	end
	return false
end

--- 隔离任务的原始位置是否有任一「重新出现」（用于还原）。
--- 与 task_live 口径一致：TODO 需文件回来且仍含该 id（否则还原后
--- 会在同一次 sweep 的扫描阶段又被隔离，来回抖动）。
---@param task Task|nil
---@param exists fun(path: string|nil): boolean
---@param contains fun(path: string|nil, id: string): boolean
---@return boolean
local function task_has_existing_location(task, exists, contains)
	local locs = (task and task.locations) or {}
	local todo = locs.todo and locs.todo.path
	local code = locs.code and locs.code.path
	if todo and contains(todo, task.id) then
		return true
	end
	if code and exists(code) then
		return true
	end
	return false
end

---------------------------------------------------------------------
-- 隔离桶读写
---------------------------------------------------------------------

--- 全部孤儿 id
---@return string[]
function M.ids()
	return store.get_namespace_keys(ORPHAN_NS) or {}
end

--- 隔离记录数量
---@return integer
function M.count()
	local n = 0
	for _ in ipairs(M.ids()) do
		n = n + 1
	end
	return n
end

--- 读取单条隔离记录
---@param id string
---@return table|nil
function M.get(id)
	return store.get_key(ORPHAN_PREFIX .. id)
end

--- 删除单条隔离记录（真正清除）
---@param id string
function M.purge(id)
	store.delete_key(ORPHAN_PREFIX .. id)
end

---------------------------------------------------------------------
-- 隔离 / 还原
---------------------------------------------------------------------

--- 把主库任务移入隔离桶（保留父子关系供还原）
---@param id string
---@param snapshot? { parent: string|nil, children: string[]|nil } 扫描时的关系快照
---@return boolean
function M.quarantine(id, snapshot)
	local task = core.get_task(id)
	if not task then
		return false
	end

	local parent, children
	if snapshot then
		parent = snapshot.parent
		children = vim.deepcopy(snapshot.children or {})
	else
		parent = relation.get_parent_id(id)
		-- get_child_ids 可能返回 store 内部表引用：必须拷贝，
		-- 否则 core.delete_task 解除关系时会连带清空隔离记录。
		children = vim.deepcopy(relation.get_child_ids(id))
	end

	local record = {
		task = vim.deepcopy(task),
		parent = parent,
		children = children,
		orphaned_at = os.time(),
	}

	store.set_key(ORPHAN_PREFIX .. id, record)
	-- core.delete_task 会解除父子关系、清索引、删主库 task/ctx；
	-- 隔离桶键前缀不同，不受影响。
	-- 隔离=可逆移动，不写删除墓碑；否则文件恢复后会被墓碑挡住无法还原。
	core.delete_task(id, { tombstone = false })
	return true
end

--- 把隔离任务的数据写回主库（不处理关系，保留记录供第二阶段连线）。
---@param id string
---@return boolean restored
local function restore_data(id)
	local record = M.get(id)
	if not record then
		return false
	end
	-- 墓碑优先：该 id 已被显式删除，隔离副本不得复活。
	if tombstone.is_deleted(id) then
		M.purge(id)
		return false
	end
	-- 主库已存在同 id（文件重现后 sync 重建的副本）：丢弃隔离副本。
	if core.get_task(id) then
		M.purge(id)
		return false
	end
	core.save_task(id, vim.deepcopy(record.task or {}))
	return true
end

--- 第二阶段：根据隔离记录重建仍存活的父子关系，然后清除记录。
--- 两阶段处理可对任意还原顺序保持鲁棒。
---@param id string
---@return boolean
local function relink(id)
	local record = M.get(id)
	if not record then
		return false
	end
	if core.get_task(id) then
		if record.parent and core.get_task(record.parent) then
			relation.set_parent_child(record.parent, id)
		end
		for _, child_id in ipairs(record.children or {}) do
			if core.get_task(child_id) then
				relation.set_parent_child(id, child_id)
			end
		end
	end
	M.purge(id)
	return true
end

---------------------------------------------------------------------
-- 扫描 / 回收
---------------------------------------------------------------------

--- 计算每个 id 的子树内是否有存活锚点（静态快照，扫描期间不受隔离影响）
---@param tasks table<string, Task>
---@param live table<string, boolean>
---@param children table<string, string[]>
---@return fun(id: string): boolean
local function make_subtree_live(tasks, live, children)
	local memo = {}
	local function subtree_live(id)
		if memo[id] ~= nil then
			return memo[id]
		end
		if live[id] then
			memo[id] = true
			return true
		end
		for _, child_id in ipairs(children[id] or {}) do
			if tasks[child_id] and subtree_live(child_id) then
				memo[id] = true
				return true
			end
		end
		memo[id] = false
		return false
	end
	return subtree_live
end

--- 执行一次回收：还原 / 去重 / 清除已有隔离，再隔离新的孤儿。
---@param opts? { force?: boolean }
---@return { quarantined: integer, restored: integer, purged: integer }
function M.sweep(opts)
	opts = opts or {}
	local cfg = config.get("orphan") or {}
	local enabled = cfg.enabled ~= false
	local retention = tonumber(cfg.retention_days) or 0
	local now = os.time()

	local result = { quarantined = 0, restored = 0, purged = 0 }

	if not enabled and not opts.force then
		return result
	end

	-- 本次扫描共用的文件探针（内部按路径缓存）
	local exists, contains = make_file_probe()

	-- 1) 处理已有隔离记录：文件恢复则还原；文件仍缺失且过期则清除。
	local to_restore = {}
	for _, id in ipairs(M.ids()) do
		local record = M.get(id)
		if not record then
			store.delete_key(ORPHAN_PREFIX .. id)
		elseif task_has_existing_location(record.task, exists, contains) then
			-- 先写回数据，关系在第二阶段统一重建（不依赖还原顺序）。
			if restore_data(id) then
				to_restore[#to_restore + 1] = id
			end
		elseif core.get_task(id) then
			-- 文件重现后 sync 已重建同 id 主库任务，丢弃隔离副本
			M.purge(id)
		elseif retention > 0 and (now - (record.orphaned_at or now)) >= retention * SECONDS_PER_DAY then
			M.purge(id)
			result.purged = result.purged + 1
		end
	end
	for _, id in ipairs(to_restore) do
		if relink(id) then
			result.restored = result.restored + 1
		end
	end

	-- 2) 扫描主库，隔离新的孤儿（子树内任一成员有存活锚点则整棵保留）。
	local ids = store.get_namespace_keys(namespace.facts.tasks_ns) or {}
	local tasks, live, children, parent_of = {}, {}, {}, {}
	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task then
			tasks[id] = task
			live[id] = task_live(task, exists, contains)
		end
	end
	-- 隔离会解除父子关系，先快照，保证还原时关系完整。
	-- 必须深拷贝：store 可能返回内部表引用，隔离时会原地变动。
	for id in pairs(tasks) do
		children[id] = vim.deepcopy(relation.get_child_ids(id))
		parent_of[id] = relation.get_parent_id(id)
	end

	local subtree_live = make_subtree_live(tasks, live, children)
	for _, id in ipairs(ids) do
		if tasks[id] and not subtree_live(id) then
			if M.quarantine(id, { parent = parent_of[id], children = children[id] }) then
				result.quarantined = result.quarantined + 1
			end
		end
	end

	return result
end

return M
