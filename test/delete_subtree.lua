-- 子树删除回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-subtree-xdg nvim --headless -u NONE -l test/delete_subtree.lua
--
-- 覆盖：折叠态下按 <BS> 删除父任务时，整棵子树（父 + 全部后代）连同
--       TODO 行、正文块、store 记录、父子关系一并删除，且不影响同级任务。
--       核心回归：不能因为「删父后子任务行号上移」而漏删文件行。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-subtree-test-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-subtree-test-proj"), "rf")

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
local relation = require("todo2.store.task.relation")
local sync = require("todo2.core.sync")
local deleter = require("todo2.task.deleter")

local f = actions.create_todo_file("subtree")
local path = f and f.path
check("create todo file", path ~= nil, path)

local p = actions.create_task({ content = "parent P", path = path })
local c1 = actions.create_task({ content = "child C1", path = path, parent_id = p.id })
local c2 = actions.create_task({ content = "child C2", path = path, parent_id = p.id })
local s = actions.create_task({ content = "sibling S", path = path })
check("tasks created", p and c1 and c2 and s, p and p.id)
check("relation c1->p", relation.get_parent_id(c1.id) == p.id)
check("relation c2->p", relation.get_parent_id(c2.id) == p.id)

-- 在父任务下插入正文块（正文与任务强绑定，删除时应一并移除）
local bufnr = vim.fn.bufadd(path)
vim.fn.bufload(bufnr)
local pline = core.get_task(p.id).locations.todo.line
vim.api.nvim_buf_set_lines(bufnr, pline, pline, false, {
	"  parent desc one",
	"  parent desc two",
})
sync.sync_todo_file(path)

local function buf_lines()
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end
local function any_line_has(id)
	for _, l in ipairs(buf_lines()) do
		if l:find(id, 1, true) then
			return true
		end
	end
	return false
end
local function has_text(txt)
	for _, l in ipairs(buf_lines()) do
		if l == txt then
			return true
		end
	end
	return false
end

-- 前置不变量：三行都在，正文块存在
check("pre: parent line", any_line_has(p.id))
check("pre: c1 line", any_line_has(c1.id))
check("pre: c2 line", any_line_has(c2.id))
check("pre: sibling line", any_line_has(s.id))
check("pre: desc block", has_text("  parent desc one") and has_text("  parent desc two"))

-- 删除父任务（等价折叠态 <BS>）：应连整棵子树一起删
local ok, res = deleter.delete_subtree(p.id)
check("delete_subtree ok", ok == true, vim.inspect(res))
check("deleted 3 tasks", res and res.succeeded == 3, vim.inspect(res))

-- store：整棵子树消失，墓碑已写，同级任务存活
local tombstone = require("todo2.store.tombstone")
check("parent gone", core.get_task(p.id) == nil)
check("child1 gone", core.get_task(c1.id) == nil)
check("child2 gone", core.get_task(c2.id) == nil)
check("sibling kept", core.get_task(s.id) ~= nil)
check("tombstone parent", tombstone.is_deleted(p.id))
check("tombstone child", tombstone.is_deleted(c2.id))

-- 关系：不再有悬空子引用
check("no children left", #relation.get_child_ids(p.id) == 0, vim.inspect(relation.get_child_ids(p.id)))
check("no dangling parent", relation.get_parent_id(c1.id) == nil)

-- 文件：子树行与正文块全部移除，同级行保留且仅一次
check("post: no parent line", not any_line_has(p.id))
check("post: no c1 line", not any_line_has(c1.id))
check("post: no c2 line", not any_line_has(c2.id))
check("post: desc removed", not has_text("  parent desc one") and not has_text("  parent desc two"))
check("post: sibling kept", any_line_has(s.id))

-- 再次删除存活任务，确认叶子删除路径仍正常
local ok2 = deleter.delete_subtree(s.id)
check("leaf delete ok", ok2 == true)
check("leaf gone", core.get_task(s.id) == nil)
check("post: no sibling line", not any_line_has(s.id))

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
