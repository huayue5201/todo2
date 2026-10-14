-- 存储命名空间契约测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-ns-xdg nvim --headless -u NONE -l test/store_namespace.lua
--
-- 覆盖：legacy 清理（todo.* 一次性清空）、cache 可丢弃重建（reset_cache）、
--       facts 不受 reset_cache 影响。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-ns-test-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local namespace = require("todo2.store.namespace")
local store = require("todo2.store.nvim_store")

-- 1) 建立旧命名空间键
store.set_key("todo.tasks.t1", { id = "t1" })
store.set_key("todo.task_ctx.t1", { todo = { path = "/x.md", line = 1 } })
store.set_key("todo.relation.child_to_parent.t1", "root")
store.set_key("todo.index.file_to_todo./x.md", { "t1" })
store.set_key("todo.orphan.t1", { orphaned_at = 1 })
store.set_key("todo.deleted.t1", { deleted_at = 1 })
store.set_key("todo.archive.index", { t1 = {} })
store.set_key("git_last_synced_commit", "deadbeef")

namespace.purge_legacy()

check("legacy tasks purged", #store.get_namespace_keys("todo.tasks") == 0)
check("legacy ctx purged", #store.get_namespace_keys("todo.task_ctx") == 0)
check("legacy relation purged", #store.get_namespace_keys("todo.relation") == 0)
check("legacy index purged", #store.get_namespace_keys("todo.index") == 0)
check("legacy orphan purged", #store.get_namespace_keys("todo.orphan") == 0)
check("legacy deleted purged", #store.get_namespace_keys("todo.deleted") == 0)
check("legacy archive index purged", store.get_key("todo.archive.index") == nil)
check("legacy git cursor purged", store.get_key("git_last_synced_commit") == nil)

-- 2) 写入 facts + cache
store.set_key(namespace.facts.tasks .. "t2", { id = "t2" })
store.set_key(namespace.facts.task_ctx .. "t2", { todo = { path = "/y.md", line = 2 } })
store.set_key(namespace.facts.deleted .. "t2", { deleted_at = 2 })
store.set_key(namespace.cache.parent_to_children .. "p", { "t2" })
store.set_key(namespace.cache.child_to_parent .. "t2", "p")
store.set_key(namespace.cache.file_to_todo .. "/y.md", { "t2" })

namespace.reset_cache()

check("cache relation cleared", #store.get_namespace_keys(namespace.cache.relation_ns) == 0)
check("cache index cleared", #store.get_namespace_keys(namespace.cache.index_ns) == 0)
check("facts task survives reset", store.get_key(namespace.facts.tasks .. "t2") ~= nil)
check("facts ctx survives reset", store.get_key(namespace.facts.task_ctx .. "t2") ~= nil)
check("facts tombstone survives reset", store.get_key(namespace.facts.deleted .. "t2") ~= nil)
check("new task not treated as legacy", #store.get_namespace_keys(namespace.facts.tasks_ns) == 1)

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
