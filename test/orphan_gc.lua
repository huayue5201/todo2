-- 孤儿任务回收测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-orphan-xdg nvim --headless -u NONE -l test/orphan_gc.lua
--
-- 覆盖：外部删除 TODO 文件 → 隔离；文件恢复 → 自动还原；超期 → 清除；
--       无位置任务 / 有存活代码锚点的任务不被隔离。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-orphan-test-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-orphan-test-proj"), "rf")

require("todo2").setup({})

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local actions = require("todo2.ai.actions")
local core = require("todo2.store.task.core")
local store = require("todo2.store.nvim_store")
local orphan = require("todo2.store.orphan")

local f = actions.create_todo_file("orphan")
check("create todo file", f and f.path ~= nil, f and f.path)
local path = f and f.path

local a = actions.create_task({ content = "orphan alpha", path = path })
check("create task", a and a.id ~= nil, a and a.id)
local aid = a and a.id
check("active contains task", aid and core.get_task(aid) ~= nil)

-- 1) 插件外删除 TODO 文件 → 隔离（不硬删）
vim.fn.delete(path)
local r = orphan.sweep()
check("quarantined >= 1", r.quarantined >= 1, vim.inspect(r))
check("removed from active", core.get_task(aid) == nil)
check("orphan recorded", orphan.get(aid) ~= nil)
check("ids contains id", vim.tbl_contains(orphan.ids(), aid))

-- 2) 文件恢复 → 自动还原
vim.fn.writefile({ "- [ ] orphan alpha " .. aid }, path)
local r2 = orphan.sweep()
check("restored >= 1", r2.restored >= 1, vim.inspect(r2))
check("active back", core.get_task(aid) ~= nil)
check("orphan cleared", orphan.get(aid) == nil)

-- 3) 再次删除并伪造超期 → 清除
vim.fn.delete(path)
orphan.sweep()
local rec = orphan.get(aid)
check("re-quarantined", rec ~= nil)
if rec then
	rec.orphaned_at = os.time() - 31 * 86400
	store.set_key("todo.orphan." .. aid, rec)
end
local r3 = orphan.sweep()
check("purged >= 1", r3.purged >= 1, vim.inspect(r3))
check("orphan gone", orphan.get(aid) == nil)
check("still gone from active", core.get_task(aid) == nil)

-- 4) 有存活代码锚点的任务：TODO 文件没了也不隔离
local lib = projdir .. "/lib.lua"
vim.fn.writefile({ "local function foo()", "  return 1", "end", "return foo" }, lib)
local fpath = projdir .. "/anchor.todo.md"
vim.fn.writefile({ "## Active" }, fpath)
local b2 = actions.create_task({ content = "has live code anchor", path = fpath })
check("create anchored task", b2 and b2.id ~= nil, b2 and b2.id)
if b2 then
	actions.link_code(b2.id, lib, 1)
	vim.fn.delete(fpath)
	local r4 = orphan.sweep()
	check("live code anchor kept", orphan.get(b2.id) == nil and core.get_task(b2.id) ~= nil, vim.inspect(r4))
end

-- 5) 无任何位置的任务：保守保留
local nid = core.create_task({ content = "no location" })
orphan.sweep()
check("anchorless task kept", orphan.get(nid) == nil and core.get_task(nid) ~= nil)

-- 6) 父子子树：同一文件删除后整棵隔离，文件恢复后关系完整还原
local f2 = actions.create_todo_file("tree")
local ppath = f2.path
local p = actions.create_task({ content = "parent P", path = ppath })
local c = actions.create_task({ content = "child C", path = ppath, parent_id = p.id })
check("parent/child created", p and c and c.id ~= nil)
vim.fn.delete(ppath)
local r5 = orphan.sweep()
check("subtree both quarantined", orphan.get(p.id) ~= nil and orphan.get(c.id) ~= nil, vim.inspect(r5))
check("subtree removed from active", core.get_task(p.id) == nil and core.get_task(c.id) == nil)
vim.fn.writefile({ "## Active", "- [ ] parent P todo:" .. p.id, "  - [ ] child C todo:" .. c.id }, ppath)

orphan.sweep()
local relation = require("todo2.store.task.relation")
check("subtree restored", core.get_task(p.id) ~= nil and core.get_task(c.id) ~= nil)
check("relation restored", relation.get_parent_id(c.id) == p.id)

-- 7) delete_task 需清干净全部子关系（store.get_key 返回内部引用，遍历需副本）
local mp = core.create_task({ content = "multi parent" })
local mcs = {}
for i = 1, 4 do
	mcs[i] = core.create_task({ content = "mc" .. i, parent_id = mp })
end
core.delete_task(mp)
local dangling = {}
for _, mcid in ipairs(mcs) do
	if relation.get_parent_id(mcid) ~= nil then
		dangling[#dangling + 1] = mcid
	end
end
check("delete_task clears all child relations", #dangling == 0, vim.inspect(dangling))

-- 8) 幽灵判活：TODO 文件还在、但任务行已从文件中删掉 → 应判失联，
--    不能再靠「文件存在」续命（这是幽灵任务一直判活的根因）。
local g = actions.create_todo_file("ghost")
local gpath = g.path
local gt = actions.create_task({ content = "ghost task", path = gpath })
vim.fn.writefile({ "## Active" }, gpath)
local r6 = orphan.sweep()
check("ghost (line removed) quarantined", orphan.get(gt.id) ~= nil and core.get_task(gt.id) == nil, vim.inspect(r6))

-- 9) 文件即真源：显式删除后，若 TODO 文件里再次出现同一 id 的行
--    （= 编辑器撤销 u / 手工回写），应按文件重建任务，并清除旧墓碑。
local tombstone = require("todo2.store.tombstone")
local sync = require("todo2.core.sync")
local d = actions.create_todo_file("tomb")
local dpath = d.path
local dt = actions.create_task({ content = "to delete", path = dpath })
actions.delete_task(dt.id)
check("tombstone written on delete", tombstone.is_deleted(dt.id))
-- 把已删除的行重新写回缓冲区（模拟编辑器撤销 / 手工回写）
local dbuf = vim.fn.bufadd(dpath)
vim.fn.bufload(dbuf)
vim.api.nvim_buf_set_lines(dbuf, 0, -1, false, {
	"## Active",
	"- [ ] to delete todo:" .. dt.id,
})
sync.sync_todo_file(dpath)
check("file reappearance rebuilds task despite tombstone", core.get_task(dt.id) ~= nil, "task stayed deleted")
check("rebuild clears tombstone", not tombstone.is_deleted(dt.id))

-- 10) 非显式删除：任务行从文件消失（可能只是编辑中的剪切/移动）不应写墓碑，
--     行重新出现时应该能重建。
local t = actions.create_todo_file("transient")
local tpath = t.path
local tt = actions.create_task({ content = "transient", path = tpath })
local tbuf = vim.fn.bufadd(tpath)
vim.fn.bufload(tbuf)
vim.api.nvim_buf_set_lines(tbuf, 0, -1, false, { "## Active" })
sync.sync_todo_file(tpath)
check("line removal deletes task", core.get_task(tt.id) == nil)
check("no tombstone for file removal", not tombstone.is_deleted(tt.id))
vim.api.nvim_buf_set_lines(tbuf, 0, -1, false, { "## Active", "- [ ] transient todo:" .. tt.id })
sync.sync_todo_file(tpath)
check("reappearing line rebuilds task", core.get_task(tt.id) ~= nil)

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
