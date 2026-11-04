-- lua/todo2/store/project_gc.lua
-- 项目级回收：项目从磁盘消失（删了、改名了、换了机器）之后，TODO 目录和 store 里的
-- 事实该怎么处理。
--
-- 原则与任务级回收（store/orphan.lua）一致，但**更保守**：
--   * TODO 文件是唯一不可重建的东西，永不自动删除，只移动；
--   * store 里的 facts 跟着 TODO 目录走，TODO 目录还在就不动它；
--   * 只有 ENOENT 才算「项目没了」，权限/IO 错误一律当它还活着；
--   * 保留期内项目回来了（断网挂载、误删还原）什么都不用做，目录一直在原地。
-- 因此这里没有 purge：确认无用后由人删除隔离区里的目录。

local M = {}

local config = require("todo2.config")
local project = require("todo2.utils.project")

--- 隔离区（`~/.todo-files/.quarantine/`，隐藏目录，不会被当成项目列出）
local QUARANTINE = ".quarantine"
local SECONDS_PER_DAY = 86400

---------------------------------------------------------------------
-- 读取
---------------------------------------------------------------------

---@param path string
---@return table|nil
local function read_json(path)
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
	return ok and type(data) == "table" and data or nil
end

--- store 里登记过的项目：项目根 → { key, accessed_at }
---@return table<string, {key: string, accessed_at: number}>, string|nil
local function scan_store()
	local out = {}
	local ok, path = pcall(require, "nvim-store3.util.path")
	if not ok then
		return out, nil
	end
	local base = path.store_root() .. "/projects"
	if vim.fn.isdirectory(base) == 0 then
		return out, base
	end
	for key, kind in vim.fs.dir(base) do
		if kind == "directory" then
			local meta = read_json(base .. "/" .. key .. "/meta.json")
			if meta and type(meta.root) == "string" then
				out[meta.root] = { key = key, accessed_at = tonumber(meta.accessed_at) or 0 }
			end
		end
	end
	return out, base
end

--- 目录里最后一次真实活动的时间。
--- 清单（.project.json）是插件自己写的账本，不算活动，否则活着的目录永远是「刚刚」。
---@param dir string
---@return number
local function last_activity(dir)
	local newest = 0
	for name, kind in vim.fs.dir(dir) do
		if kind == "file" and name ~= ".project.json" then
			local stat = vim.loop.fs_stat(dir .. "/" .. name)
			if stat and stat.mtime.sec > newest then
				newest = stat.mtime.sec
			end
		end
	end
	if newest == 0 then
		local stat = vim.loop.fs_stat(dir)
		newest = stat and stat.mtime.sec or 0
	end
	return newest
end

---------------------------------------------------------------------
-- 扫描
---------------------------------------------------------------------

---@class ProjectGcEntry
---@field name string
---@field dir string
---@field label string
---@field root string|nil
---@field identity string|nil
---@field store_key string|nil
---@field last_active number
---@field known boolean 目录里有 .project.json（知道它属于哪个项目）

---@class ProjectGcReport
---@field alive ProjectGcEntry[]    项目根还在
---@field gone ProjectGcEntry[]     项目根没了（ENOENT），目录还在原地
---@field unknown ProjectGcEntry[]  没有清单，无法判断归属
---@field orphaned table[]          store 里有、TODO 目录没有的项目

--- 扫描 vault 与 store，只读，不做任何改动。
---@return ProjectGcReport
function M.scan()
	local vault = project.vault_root()
	local store, store_base = scan_store()
	local report = { alive = {}, gone = {}, unknown = {}, orphaned = {} }
	local touched = {}

	for name, kind in vim.fs.dir(vault) do
		if kind == "directory" and name:sub(1, 1) ~= "." then
			local dir = vault .. "/" .. name
			local manifest = project.read_manifest(dir)
			local root = manifest and manifest.root or nil
			local info = {
				name = name,
				dir = dir,
				label = manifest and manifest.label or name,
				root = root,
				identity = manifest and manifest.identity,
				store_key = root and store[root] and store[root].key or nil,
				last_active = last_activity(dir),
				known = manifest ~= nil and root ~= nil,
			}
			if info.store_key and store[root].accessed_at > info.last_active then
				info.last_active = store[root].accessed_at
			end
			if not info.known then
				report.unknown[#report.unknown + 1] = info
			else
				touched[root] = true
				local stat, _, errname = vim.loop.fs_stat(root)
				if stat then
					report.alive[#report.alive + 1] = info
				elseif errname == "ENOENT" then
					report.gone[#report.gone + 1] = info
				else
					-- 读不到不等于没了（权限、IO、挂载抖动）
					report.alive[#report.alive + 1] = info
				end
			end
		end
	end

	if store_base and vim.fn.isdirectory(store_base) == 1 then
		for root, item in pairs(store) do
			if not touched[root] then
				report.orphaned[#report.orphaned + 1] = {
					root = root,
					store_key = item.key,
					accessed_at = item.accessed_at,
				}
			end
		end
	end

	table.sort(report.alive, function(a, b)
		return a.label < b.label
	end)
	table.sort(report.gone, function(a, b)
		return a.last_active < b.last_active
	end)
	table.sort(report.unknown, function(a, b)
		return a.name < b.name
	end)
	return report
end

---------------------------------------------------------------------
-- 回收
---------------------------------------------------------------------

---@param entry ProjectGcEntry
---@param now number
---@return boolean
local function is_expired(entry, now)
	local days = tonumber(config.get("projects.retention_days")) or 0
	if days <= 0 then
		return false
	end
	return now - entry.last_active >= days * SECONDS_PER_DAY
end

---@param entry ProjectGcEntry
---@param now number
---@return string
local function quarantine_dir(entry, now)
	return table.concat({
		project.vault_root(),
		QUARANTINE,
		os.date("%Y-%m-%d", now) .. "_" .. entry.name,
	}, "/")
end

--- 把「项目已从磁盘消失、且超过保留期」的 TODO 目录移进隔离区。
---@param opts { apply: boolean|nil, now: number|nil }|nil
---@return { moved: string[], kept: ProjectGcEntry[], report: ProjectGcReport }
function M.run(opts)
	opts = opts or {}
	local now = opts.now or os.time()
	local report = M.scan()
	local moved, kept = {}, {}

	for _, entry in ipairs(report.gone) do
		if not is_expired(entry, now) then
			kept[#kept + 1] = entry
		else
			local target = quarantine_dir(entry, now)
			if vim.fn.isdirectory(target) == 1 then
				-- 同一天已经被隔离过一次：不合并、不覆盖，交给人看
				vim.notify("todo2: quarantine target exists, skipping " .. entry.dir, vim.log.levels.WARN)
			elseif opts.apply then
				vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
				local ok, err = pcall(vim.fn.rename, entry.dir, target)
				if not ok then
					vim.notify("todo2: cannot quarantine " .. entry.dir .. ": " .. tostring(err), vim.log.levels.WARN)
				else
					moved[#moved + 1] = target
				end
			else
				moved[#moved + 1] = target
			end
		end
	end

	return { moved = moved, kept = kept, report = report }
end

--- `:TodoDoctor` 用的一行摘要。
---@return string
function M.summary()
	local report = M.scan()
	return string.format(
		"projects: %d alive, %d gone, %d unknown, %d store-only",
		#report.alive,
		#report.gone,
		#report.unknown,
		#report.orphaned
	)
end

return M
