-- 过期回收测试（headless，自包含）：墓碑与隔离区按 config.expire 清理。
-- 运行：nvim --headless -u NONE -l test/expire.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local proj = "/tmp/todo2-expire-proj"
vim.fn.delete(proj, "rf")
vim.fn.mkdir(proj, "p")
vim.fn.chdir(proj)

require("todo2").setup({})
vim.cmd("runtime plugin/todo2.lua")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local project_utils = require("todo2.utils.project")
local me = project_utils.current()
vim.fn.mkdir(me.dir, "p")

local config = require("todo2.config")
local expire = require("todo2.store.expire")
local namespace = require("todo2.store.namespace")
local store = require("todo2.store.nvim_store")
local tombstone = require("todo2.store.tombstone")

local DAY = 86400
local now = os.time()
local days = tonumber(config.get("expire").days)
check("expire 默认开启且 180 天", config.get("expire").enabled == true and days == 180, days)

-- 墓碑：一条 200 天前、一条 1 天前
tombstone.mark("oldold")
tombstone.mark("newnew")
store.set_key(namespace.facts.deleted .. "oldold", { deleted_at = now - 200 * DAY, reason = "delete" })
store.set_key(namespace.facts.deleted .. "newnew", { deleted_at = now - DAY, reason = "delete" })

-- 隔离区：一份 200 天前的目录、一份当天的目录、一个文件（不该被当目录处理）
local quarantine = project_utils.vault_root() .. "/.quarantine"
vim.fn.delete(quarantine, "rf")
vim.fn.mkdir(quarantine .. "/" .. os.date("%Y-%m-%d", now - 200 * DAY) .. "_old-proj", "p")
vim.fn.mkdir(quarantine .. "/" .. os.date("%Y-%m-%d", now) .. "_new-proj", "p")
vim.fn.writefile({ "keep me" }, quarantine .. "/" .. os.date("%Y-%m-%d", now - 200 * DAY) .. "_old-proj/a.todo.md")
vim.fn.writefile({ "stray" }, quarantine .. "/notes.txt")

local r = expire.run({ now = now })
check("清掉过期墓碑", r.tombstones == 1, r.tombstones)
check("墓碑 oldold 已删", store.get_key(namespace.facts.deleted .. "oldold") == nil)
check("墓碑 newnew 保留", store.get_key(namespace.facts.deleted .. "newnew") ~= nil)
check("清掉过期隔离目录", r.quarantined == 1, r.quarantined)
check(
	"过期隔离目录已删",
	vim.fn.isdirectory(quarantine .. "/" .. os.date("%Y-%m-%d", now - 200 * DAY) .. "_old-proj") == 0
)
check(
	"未过期隔离目录保留",
	vim.fn.isdirectory(quarantine .. "/" .. os.date("%Y-%m-%d", now) .. "_new-proj") == 1
)
check("隔离区里的散落文件不动", vim.fn.filereadable(quarantine .. "/notes.txt") == 1)

-- 目录名不是「日期_名字」时按 mtime 判断，不会被误删
local odd = quarantine .. "/manual-copy"
vim.fn.mkdir(odd, "p")
check("无日期前缀的目录按 mtime 保留", expire.run({ now = now }).quarantined == 0)

-- 开关：enabled = false 时什么都不动
local get = config.get
config.get = function(key, default)
	if key == "expire" then
		return { enabled = false, days = 180 }
	end
	return get(key, default)
end
store.set_key(namespace.facts.deleted .. "oldold", { deleted_at = now - 200 * DAY, reason = "delete" })
local off = expire.run({ now = now })
check("关闭时不动墓碑", off.tombstones == 0 and store.get_key(namespace.facts.deleted .. "oldold") ~= nil)
check("关闭时不动隔离区", off.quarantined == 0)
config.get = get

-- days = 0 表示永不删除
config.get = function(key, default)
	if key == "expire" then
		return { enabled = true, days = 0 }
	end
	return get(key, default)
end
check("days = 0 时不动任何东西", expire.run({ now = now }).tombstones == 0)
config.get = get

-- 没有隔离区目录时不报错
vim.fn.delete(quarantine, "rf")
check("隔离区不存在时无副作用", expire.run({ now = now }).quarantined == 0)

-- 真实 TODO 文件永不被这里删除
local todo_dir = me.dir
vim.fn.writefile({ "- [ ] 活着 @id(eeee01)" }, todo_dir .. "/live.todo.md")
expire.run({ now = now + 3650 * DAY })
check("TODO 文件不受影响", vim.fn.filereadable(todo_dir .. "/live.todo.md") == 1)

-- 清理
store.delete_key(namespace.facts.deleted .. "newnew")
store.delete_key(namespace.facts.deleted .. "oldold")
vim.fn.delete(todo_dir, "rf")
vim.fn.delete(quarantine, "rf")
vim.fn.delete(proj, "rf")
print(fails == 0 and "ALL OK" or ("FAILURES: " .. fails))
vim.cmd(fails == 0 and "qa!" or "cq")
