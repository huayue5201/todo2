-- 存储数据形状契约测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-schema-xdg nvim --headless -u NONE -l test/schema.lua
--
-- 目的：把「老数据 → 当前形状」的适配钉在 store.schema 里。
--   * v1 之前的 fixture（缺字段 / 遗留字段 / 脏值）读出来必须是完整 Task
--   * TASK_CONTRACT 的每个必需字段都要有（新增字段忘了给默认值 → 这里红）
--   * 字典型 facts（墓碑 / 孤儿快照）形状不对时返回 nil 而不是带病使用

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-schema-proj"
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)

require("todo2").setup({})

local schema = require("todo2.store.schema")
local store = require("todo2.store.nvim_store")
local namespace = require("todo2.store.namespace")
local core = require("todo2.store.task.core")
local tombstone = require("todo2.store.tombstone")
local types = require("todo2.store.types")
local config = require("todo2.config")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

-- 测试自清理：删掉本用例写入的键（nvim_store 没有 clear_all）
local function drop(...)
	for _, key in ipairs({ ... }) do
		store.delete_key(key)
	end
end

drop(
	namespace.facts.tasks .. "old001",
	namespace.facts.task_ctx .. "old001.todo",
	namespace.facts.task_ctx .. "old001.code",
	namespace.facts.tasks .. "ok0001",
	namespace.facts.deleted .. "tomb01",
	namespace.facts.deleted .. "tomb02",
	namespace.facts.orphan .. "orph01",
	schema.VERSION_KEY
)

---------------------------------------------------------------------
-- 1) 老形状任务记录 → 当前 Task
---------------------------------------------------------------------
local LEGACY_ID = "old001"
store.set_key(namespace.facts.tasks .. LEGACY_ID, {
	core = {
		id = LEGACY_ID, -- 历史冗余字段
		content_hash = "deadbeef", -- 历史冗余字段
		sync_status = "synced", -- 历史冗余字段
		content = "老任务",
		status = "no-such-status", -- 未知状态
		due = "2026-02-31", -- 非法日期
		-- 缺 tags
	},
	-- 缺 timestamps
	verification = { needs_relocate = false }, -- 老布尔字段
	git = { commit = "abc123", branch = "main" },
})
store.set_key(namespace.facts.task_ctx .. LEGACY_ID .. ".todo", { path = "/tmp/a.todo.md", line = 0 })
store.set_key(namespace.facts.task_ctx .. LEGACY_ID .. ".code", {
	path = "/tmp/a.go",
	line = -3,
	col = -1,
	snippet = "",
})

local task = core.get_task(LEGACY_ID)
check("legacy record loads", task ~= nil)
if task then
	check("legacy core.id stripped", task.core.id == nil)
	check("legacy content_hash stripped", task.core.content_hash == nil)
	check("legacy sync_status stripped", task.core.sync_status == nil)
	check("content preserved", task.core.content == "老任务", task.core.content)
	check("unknown status normalized", task.core.status == config.get_default_status(), task.core.status)
	check("illegal due dropped", task.core.due == nil, tostring(task.core.due))
	check("missing tags become empty table", type(task.core.tags) == "table" and #task.core.tags == 0)
	check("missing timestamps default to 0", task.timestamps.created == 0 and task.timestamps.updated == 0, vim.inspect(task.timestamps))
	check("legacy verification state recovered", task.verification.state == schema.ANCHOR.OK, task.verification.state)
	check("git metadata preserved", task.git and task.git.commit == "abc123")
	check("todo location line clamped to 1", task.locations.todo.line == 1, task.locations.todo.line)
	check("code location col clamped to 0", task.locations.code.col == 0, tostring(task.locations.code.col))
	check("empty snippet dropped", task.locations.code.snippet == nil)
	check("no end_col without col... kept consistent", task.locations.code.col == 0)

	-- 契约字段清单：新增字段必须同步到 schema.normalize_task
	for _, field in ipairs(schema.TASK_CONTRACT.root) do
		check("contract root." .. field, task[field] ~= nil)
	end
	for _, field in ipairs(schema.TASK_CONTRACT.core) do
		check("contract core." .. field, task.core[field] ~= nil)
	end
	for _, field in ipairs(schema.TASK_CONTRACT.core_optional) do
		-- 可选字段：缺省 = 没有该时间维度（nil），有值时必须是合法日期
		check(
			"contract core_optional." .. field,
			task.core[field] == nil or require("todo2.utils.due").is_date(task.core[field])
		)
	end
	for _, field in ipairs(schema.TASK_CONTRACT.timestamps) do
		check("contract timestamps." .. field, type(task.timestamps[field]) == "number")
	end
	for _, field in ipairs(schema.TASK_CONTRACT.verification) do
		check("contract verification." .. field, task.verification[field] ~= nil)
	end
	check("contract: no unlisted root keys", (function()
		local allowed = { id = true, core = true, timestamps = true, verification = true, locations = true, git = true }
		for k in pairs(task) do
			if not allowed[k] then
				return false
			end
		end
		return true
	end)(), vim.inspect(vim.tbl_keys(task)))
end

---------------------------------------------------------------------
-- 2) 合法老数据不被改动（归一必须幂等）
---------------------------------------------------------------------
local OK_ID = "ok0001"
store.set_key(namespace.facts.tasks .. OK_ID, {
	core = { content = "新任务", status = types.STATUS.TODO, tags = { "fix", "ui" }, due = "2026-11-02" },
	timestamps = { created = 100, updated = 200, completed = 150 },
	verification = { state = schema.ANCHOR.STALE },
})
local ok_task = core.get_task(OK_ID)
check("clean record keeps tags", ok_task and #ok_task.core.tags == 2, ok_task and #ok_task.core.tags)
check("clean record keeps due", ok_task and ok_task.core.due == "2026-11-02")
check("clean record keeps timestamps", ok_task and ok_task.timestamps.created == 100 and ok_task.timestamps.completed == 150)
check("clean record keeps verification", ok_task and ok_task.verification.state == schema.ANCHOR.STALE)
check("normalize is idempotent", (function()
	local once = schema.normalize_task(store.get_key(namespace.facts.tasks .. OK_ID), OK_ID)
	local twice = schema.normalize_task(once, OK_ID)
	return vim.deep_equal(once, twice)
end)())

---------------------------------------------------------------------
-- 3) 墓碑 / 孤儿记录（字典型 facts）
---------------------------------------------------------------------
local deleted_key = namespace.facts.deleted .. "tomb01"
check("tombstone garbage rejected", select(1, schema.normalize_facts(deleted_key, { reason = "x" })) == nil)
check("tombstone record repaired", (function()
	local rec = schema.normalize_facts(deleted_key, { deleted_at = 123 })
	return rec and rec.deleted_at == 123 and rec.reason == "delete"
end)())
tombstone.mark("tomb02", "archive")
check("tombstone.mark writes schema shape", (function()
	local rec = store.get_key(namespace.facts.deleted .. "tomb02")
	return rec and type(rec.deleted_at) == "number" and rec.reason == "archive"
end)(), vim.inspect(store.get_key(namespace.facts.deleted .. "tomb02")))

local orphan_key = namespace.facts.orphan .. "orph01"
check("orphan without task rejected", select(1, schema.normalize_facts(orphan_key, { orphaned_at = 1 })) == nil)
local orphan_rec = schema.normalize_facts(orphan_key, {
	-- 老快照：task 缺 tags/timestamps、带历史字段
	task = { id = "orph01", core = { content = "隔离的", status = types.STATUS.TODO, id = "legacy" } },
	parent = "",
	children = { "c1", 5, "" },
	orphaned_at = 999,
})
check("orphan task snapshot normalized", orphan_rec ~= nil and type(orphan_rec.task.core.tags) == "table")
check("orphan historical id stripped", orphan_rec ~= nil and orphan_rec.task.core.id == nil)
check("orphan empty parent dropped", orphan_rec ~= nil and orphan_rec.parent == nil)
check("orphan children filtered", orphan_rec ~= nil and #orphan_rec.children == 1 and orphan_rec.children[1] == "c1",
	vim.inspect(orphan_rec and orphan_rec.children))
check("orphan keeps timestamp", orphan_rec ~= nil and orphan_rec.orphaned_at == 999)
check("unknown facts key passes through", schema.normalize_facts("facts.something.else", { a = 1 }) ~= nil)

---------------------------------------------------------------------
-- 4) 形状版本标记
---------------------------------------------------------------------
store.delete_key(schema.VERSION_KEY)
check("version absent on old store", schema.read_version() == nil)
local stamped = schema.stamp()
check("stamp records current version", stamped.to == schema.VERSION and schema.read_version() == schema.VERSION, vim.inspect(stamped))
local again = schema.stamp()
check("stamp is idempotent", again.from == schema.VERSION)
store.set_key(schema.VERSION_KEY, schema.VERSION - 1)
local bumped = schema.stamp()
check("stamp bumps an older version", bumped.from == schema.VERSION - 1 and schema.read_version() == schema.VERSION)

drop(namespace.facts.tasks .. "old001", namespace.facts.tasks .. "ok0001")
print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
