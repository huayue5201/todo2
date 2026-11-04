-- 项目级回收测试：项目从磁盘消失后，TODO 目录怎么被处理（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/project_gc.lua
--
-- 覆盖：项目根还在 → 不碰；根没了且在保留期内 → 只报告；超期 → 移进隔离区；
--       没有清单的目录 → 只报告；store 里有、TODO 目录没有 → 只报告。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local fails, total = 0, 0
local function check(name, cond, extra)
	total = total + 1
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

require("todo2").setup({})

local project = require("todo2.utils.project")
local gc = require("todo2.store.project_gc")

local tag = "todo2-gc-test"
local live_root = "/tmp/" .. tag .. "-live"
vim.fn.delete(live_root, "rf")
vim.fn.mkdir(live_root, "p")

local vault = project.vault_root()
local function make_dir(name, manifest)
	local dir = vault .. "/" .. name
	vim.fn.delete(dir, "rf")
	vim.fn.mkdir(dir, "p")
	if manifest then
		vim.fn.writefile({ vim.json.encode(manifest) }, dir .. "/.project.json")
	end
	vim.fn.writefile({ "- [ ] a task" }, dir .. "/main.todo.md")
	return dir
end

local now = os.time()
local old = now - 60 * 86400
local today_quarantine = vault .. "/.quarantine/" .. os.date("%Y-%m-%d", now) .. "_" .. tag .. "-gone--0000bbbb"
vim.fn.delete(today_quarantine, "rf")

-- 活着：根还在
local live_dir = make_dir(tag .. "-live--0000aaaa", {
	name = tag .. "-live--0000aaaa",
	label = "live",
	identity = "local:" .. live_root,
	root = live_root,
})
-- 死了且超期：根目录从来没存在过
local gone_dir = make_dir(tag .. "-gone--0000bbbb", {
	name = tag .. "-gone--0000bbbb",
	label = "gone",
	identity = "local:/nonexistent/todo2-gc-gone",
	root = "/nonexistent/todo2-gc-gone",
})
-- 死了但还新鲜（保留期内）
local fresh_dir = make_dir(tag .. "-fresh--0000cccc", {
	name = tag .. "-fresh--0000cccc",
	label = "fresh",
	identity = "local:/nonexistent/todo2-gc-fresh",
	root = "/nonexistent/todo2-gc-fresh",
})
-- 没有清单：无法判断归属
local unknown_dir = make_dir(tag .. "-unknown--0000dddd", nil)
vim.fn.delete(unknown_dir .. "/.project.json")

-- 把两个「死」目录的活跃时间推到 60 天前
for _, dir in ipairs({ gone_dir, fresh_dir }) do
	vim.loop.fs_utime(dir .. "/main.todo.md", old, old)
	vim.loop.fs_utime(dir, old, old)
end
-- fresh 的那个要「还新鲜」，它的清单时间也不该把活跃时间拉到现在
vim.loop.fs_utime(fresh_dir .. "/main.todo.md", now, now)

---------------------------------------------------------------------
-- 1) 扫描分类
---------------------------------------------------------------------
local report = gc.scan()
local function find(list, name)
	for _, entry in ipairs(list) do
		if entry.name == name then
			return entry
		end
	end
end

check("scan: live project is alive", find(report.alive, tag .. "-live--0000aaaa") ~= nil)
check("scan: missing root is gone", find(report.gone, tag .. "-gone--0000bbbb") ~= nil)
check("scan: manifest-less dir is unknown", find(report.unknown, tag .. "-unknown--0000dddd") ~= nil)
check("scan: unknown dirs are not treated as gone", find(report.gone, tag .. "-unknown--0000dddd") == nil)
check(
	"scan: gone entries carry their store key",
	find(report.gone, tag .. "-gone--0000bbbb").store_key == nil,
	"no store entry was created for this fixture"
)

---------------------------------------------------------------------
-- 2) 保留期：新建的死项目先不动
---------------------------------------------------------------------
local result = gc.run({ apply = false, now = now })
local kept_names = {}
for _, entry in ipairs(result.kept) do
	kept_names[#kept_names + 1] = entry.name
end
check(
	"retention: fresh gone project is kept",
	vim.tbl_contains(kept_names, tag .. "-fresh--0000cccc"),
	table.concat(kept_names, ",")
)
check("retention: fresh dir still exists", vim.fn.isdirectory(fresh_dir) == 1)
check("retention: expired project is only reported", #result.moved == 1 and vim.fn.isdirectory(gone_dir) == 1, vim.inspect(result.moved))

---------------------------------------------------------------------
-- 3) 超期：移进隔离区（dry-run 只报告）
---------------------------------------------------------------------
local dry = gc.run({ apply = false, now = now })
check("dry-run: reports the move", #dry.moved == 1, vim.inspect(dry.moved))
check("dry-run: nothing moved", vim.fn.isdirectory(gone_dir) == 1)

local applied = gc.run({ apply = true, now = now })
check("apply: one directory moved", #applied.moved == 1, vim.inspect(applied.moved))
check("apply: old dir is gone", vim.fn.isdirectory(gone_dir) == 0)
check("apply: quarantine path is dated", applied.moved[1]:match("/%.quarantine/%d%d%d%d%-%d%d%-%d%d_") ~= nil, applied.moved[1])
check("apply: files travel with the directory", vim.fn.filereadable(applied.moved[1] .. "/main.todo.md") == 1)
check("apply: manifest travels too", vim.fn.filereadable(applied.moved[1] .. "/.project.json") == 1)
check("apply: live project untouched", vim.fn.isdirectory(live_dir) == 1)
check("apply: unknown dir untouched", vim.fn.isdirectory(unknown_dir) == 1)
check("apply: second run is a no-op", #gc.run({ apply = true, now = now }).moved == 0)

---------------------------------------------------------------------
-- 4) store 里有、TODO 目录没有 → 只报告，绝不删 store
---------------------------------------------------------------------
local ok, path = pcall(require, "nvim-store3.util.path")
if ok then
	local orphan_root = "/nonexistent/todo2-gc-store-only"
	local key = path.hash_path(orphan_root)
	local store_dir = path.store_root() .. "/projects/" .. key
	vim.fn.mkdir(store_dir, "p")
	vim.fn.writefile({ vim.json.encode({ root = orphan_root, accessed_at = old }) }, store_dir .. "/meta.json")

	local r2 = gc.scan()
	local found = false
	for _, item in ipairs(r2.orphaned) do
		if item.root == orphan_root then
			found = true
		end
	end
	check("store-only: reported", found)
	check("store-only: store data still there", vim.fn.filereadable(store_dir .. "/meta.json") == 1)
	vim.fn.delete(store_dir, "rf")
else
	print("SKIP store-only checks (nvim-store3 not found)")
end

---------------------------------------------------------------------
-- 5) 摘要行（:TodoDoctor 用）
---------------------------------------------------------------------
check("summary: mentions the counts", gc.summary():match("projects: %d+ alive") ~= nil, gc.summary())

vim.fn.delete(live_root, "rf")
vim.fn.delete(live_dir, "rf")
vim.fn.delete(fresh_dir, "rf")
vim.fn.delete(unknown_dir, "rf")
vim.fn.delete(today_quarantine, "rf")

print(fails == 0 and string.format("\nALL PASS (%d checks)", total) or string.format("\n%d/%d FAILED", fails, total))
if fails > 0 then
	os.exit(1)
end
