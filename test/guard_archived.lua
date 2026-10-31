-- 归档任务 = 冻结态：改日期/改标签/删除都必须被拒绝，反归档后恢复。
-- 运行：nvim --headless -u NONE -l test/guard_archived.lua
--
-- 背景：同一条"能不能改"的规则曾散落在抽屉/deleter/datefield/tags 里，
-- 结果取决于从哪个入口进来（抽屉禁改、TODO 行里随便改）。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-guard-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
local tododir = vim.fn.expand("~/.todo-files/todo2-guard-proj")
vim.fn.delete(tododir, "rf")

require("todo2").setup({})

local actions = require("todo2.ai.actions")
local core = require("todo2.store.task.core")
local archive = require("todo2.core.archive")
local datefield = require("todo2.handlers.datefield")
local tags = require("todo2.handlers.tags")
local deleter = require("todo2.task.deleter")
local types = require("todo2.store.types")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local f = actions.create_todo_file("guard")
local a = actions.create_task({ content = "会被归档的任务", path = f.path })
check("create", a and a.id)

check("archive", archive.archive_task_group(a.id) == true)
check("status is archived", core.get_task(a.id).core.status == types.STATUS.ARCHIVED)

-- 1) 改日期被拒
local ok = datefield.set_by_id("due", a.id, "2032-01-01")
check("frozen: due change rejected", ok == false, ok)
check("frozen: due unchanged", core.get_task(a.id).core.due == nil, core.get_task(a.id).core.due)

-- 2) 改标签被拒
local t, terr = tags.tags_for_id(a.id, "set", { "x" })
check("frozen: tags change rejected", t == nil, terr)

-- 3) 删除被拒（单条与子树两条路径都要挡）
local dok, dres = deleter.delete_by_ids({ a.id })
check("frozen: delete rejected", dok == false, dres and dres.details and dres.details[1] and dres.details[1].error)
local sok = deleter.delete_subtree(a.id)
check("frozen: subtree delete rejected", sok == false)
check("frozen: task still exists", core.get_task(a.id) ~= nil)

-- 4) 反归档后一切照常
check("unarchive", archive.unarchive_task_group({ a.id }) == true)
local ok2 = datefield.set_by_id("due", a.id, "2032-01-01")
check("after unarchive: due change allowed", ok2 == true)
check("due written", core.get_task(a.id).core.due == "2032-01-01", core.get_task(a.id).core.due)
local t2 = tags.tags_for_id(a.id, "set", { "y" })
check("after unarchive: tags change allowed", t2 ~= nil and t2[1] == "y", t2 and t2[1])
check("after unarchive: delete allowed", deleter.delete_by_ids({ a.id }) == true)

vim.fn.delete(tododir, "rf")
vim.fn.delete(projdir, "rf")
print(string.format("\n%s (%d failed)", fails == 0 and "ALL PASS" or "FAILURES", fails))
os.exit(fails == 0 and 0 or 1)
