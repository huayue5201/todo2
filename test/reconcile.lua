-- 全量对账（reindex）测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-reconcile-xdg nvim --headless -u NONE -l test/reconcile.lua
--
-- 覆盖：外部漂移后 reconcile 能自愈（新增任务入库、消失任务出库、行号纠正），
--       并且对已一致的状态幂等（重复运行无增删改）。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-reconcile-test-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-reconcile-test-proj"), "rf")

require("todo2").setup({})
-- 等 setup 里 vim.schedule 的启动对账/孤儿回收跑完，避免与用例交错
vim.wait(300, function()
	return false
end)

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
local reconcile = require("todo2.core.reconcile")
local id_utils = require("todo2.utils.id")

-- 建文件 + 两个任务（均已同步）
local f = actions.create_todo_file("recon")
local path = f.path
local a = actions.create_task({ content = "task A", path = path })
local b = actions.create_task({ content = "task B", path = path })
check("setup A synced", core.get_task(a.id) ~= nil)
check("setup B synced", core.get_task(b.id) ~= nil)

-- 模拟外部漂移：删掉 A 的行、新增 store 尚不知道的 C 行（不触发 sync）
local buf = vim.fn.bufadd(path)
vim.fn.bufload(buf)
local cid = id_utils.generate_id()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
	"## Active",
	"- [ ] task B todo:" .. b.id,
	"- [ ] task C todo:" .. cid,
})

check("before reconcile: A still in store", core.get_task(a.id) ~= nil)
check("before reconcile: C absent", core.get_task(cid) == nil)

local r = reconcile.run()
check("reconcile ran at least one file", r.files >= 1, vim.inspect(r))
check("reconcile added C", core.get_task(cid) ~= nil)
check("reconcile removed A", core.get_task(a.id) == nil)
check("reconcile kept B", core.get_task(b.id) ~= nil)

-- 行号应与文件一致
local btask = core.get_task(b.id)
check("B line corrected to 2", btask.locations.todo.line == 2, tostring(btask.locations.todo.line))
local ctask = core.get_task(cid)
check("C line recorded as 3", ctask.locations.todo.line == 3, tostring(ctask.locations.todo.line))

-- 幂等：再次对账不应产生增删改
local r2 = reconcile.run()
check("idempotent: no adds", r2.added == 0, vim.inspect(r2))
check("idempotent: no removes", r2.removed == 0, vim.inspect(r2))
check("idempotent: no changes", r2.changed == 0, vim.inspect(r2))

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
