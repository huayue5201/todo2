-- lua/todo2/store/expire.lua
-- 过期数据回收：删除墓碑（facts.deleted.<id>）与项目隔离区
-- （~/.todo-files/.quarantine/<日期>_<项目名>）。
--
-- 这两处都是只增不减的账本：墓碑随每次显式删除累积，隔离区随每个死项目累积。
-- 默认保留 `config.expire.days`（180 天）后真正删除，`config.expire.enabled = false`
-- 时完全不动。TODO 文件本身永不在此列——md 是真源，只有插件自己的账本才会过期。
---@module "todo2.store.expire"

local M = {}

local config = require("todo2.config")
local project = require("todo2.utils.project")
local store = require("todo2.store.nvim_store")
local namespace = require("todo2.store.namespace")

local SECONDS_PER_DAY = 86400
--- 隔离区（`~/.todo-files/.quarantine/`，隐藏目录，不会被当成项目列出）
local QUARANTINE = ".quarantine"
--- 隔离目录名形如 `2026-11-06_my-project`
local NAME_DATE = "^(%d%d%d%d)%-(%d%d)%-(%d%d)_"

--- 隔离目录的「进入隔离区的时间」来自目录名（移动时写入），没有就用 mtime。
--- 用名字而不是 mtime：把旧目录移进隔离区时 mtime 不会更新，按 mtime 会当场删掉它。
---@param path string
---@return integer
local function quarantine_time(path)
	local name = vim.fn.fnamemodify(path, ":t")
	local y, m, d = name:match(NAME_DATE)
	if y then
		local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 })
		if t then
			return t
		end
	end
	local stat = vim.loop.fs_stat(path)
	return stat and stat.mtime.sec or os.time()
end

--- 删除超过保留期的墓碑。墓碑只占几十字节，这里清的是「无上限增长」。
---@param now integer
---@param days integer
---@return integer pruned
local function prune_tombstones(now, days)
	local pruned = 0
	local prefix = namespace.facts.deleted
	for _, id in ipairs(store.get_namespace_keys(namespace.facts.deleted_ns) or {}) do
		local key = prefix .. id
		local record = store.get_key(key)
		local at = type(record) == "table" and tonumber(record.deleted_at) or nil
		if at and (now - at) >= days * SECONDS_PER_DAY then
			store.delete_key(key)
			pruned = pruned + 1
		end
	end
	return pruned
end

--- 删除超过保留期的隔离区目录（**这里会真删文件**，仅限隔离区）。
---@param now integer
---@param days integer
---@return integer pruned
local function prune_quarantine(now, days)
	local root = project.vault_root() .. "/" .. QUARANTINE
	if vim.fn.isdirectory(root) ~= 1 then
		return 0
	end
	local pruned = 0
	for name, kind in vim.fs.dir(root) do
		local path = root .. "/" .. name
		if kind == "directory" and (now - quarantine_time(path)) >= days * SECONDS_PER_DAY then
			vim.fn.delete(path, "rf")
			pruned = pruned + 1
		end
	end
	return pruned
end

--- 执行一次过期回收。
---@param opts? { force?: boolean, now?: integer }
---@return { tombstones: integer, quarantined: integer }
function M.run(opts)
	opts = opts or {}
	local cfg = config.get("expire") or {}
	local days = tonumber(cfg.days) or 0
	local result = { tombstones = 0, quarantined = 0 }

	if (not cfg.enabled) and not opts.force then
		return result
	end
	if days <= 0 then
		return result
	end

	local now = opts.now or os.time()
	result.tombstones = prune_tombstones(now, days)
	result.quarantined = prune_quarantine(now, days)
	return result
end

return M
