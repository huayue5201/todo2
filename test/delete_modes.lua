-- 删除语义回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-delete-modes-xdg nvim --headless -u NONE -l test/delete_modes.lua
--
-- 覆盖 deleter.delete 的三种显式语义：
--   forbid  = 默认；有子任务时拒绝，绝不留下孤儿
--   cascade = 连同整棵子树删除
--   promote = 只删自身，子节点提升一级（缩进各减 step，父指向祖父）

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-delete-modes-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-delete-modes-proj"), "rf")

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

local f = actions.create_todo_file("modes")
local path = f and f.path
check("create todo file", path ~= nil, path)

local bufnr = vim.fn.bufadd(path)
vim.fn.bufload(bufnr)

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
local function indent_of(id)
	for _, l in ipairs(buf_lines()) do
		if l:find(id, 1, true) then
			return #(l:match("^(%s*)") or "")
		end
	end
	return nil
end

---------------------------------------------------------------------
-- 1) forbid：删父被拒绝，文件/store 不动
---------------------------------------------------------------------
local g = actions.create_task({ content = "grand G", path = path })
local p = actions.create_task({ content = "parent P", path = path, parent_id = g.id })
local c1 = actions.create_task({ content = "child C1", path = path, parent_id = p.id })
local c2 = actions.create_task({ content = "child C2", path = path, parent_id = p.id })
sync.sync_todo_file(path)

check("setup: c1->p", relation.get_parent_id(c1.id) == p.id)
check("setup: p->g", relation.get_parent_id(p.id) == g.id)
local p_indent = indent_of(p.id)
local c_indent = indent_of(c1.id)
check("setup: nested indent", c_indent and p_indent and c_indent > p_indent, tostring(p_indent) .. "/" .. tostring(c_indent))

local ok_f, res_f = deleter.delete(p.id) -- 默认 forbid
check("forbid refuses parent", ok_f == false and res_f and res_f.error == "has_children", vim.inspect(res_f))
check("forbid: parent kept", core.get_task(p.id) ~= nil)
check("forbid: child kept", core.get_task(c1.id) ~= nil)
check("forbid: parent line kept", any_line_has(p.id))

-- forbid 删除叶子可正常完成
local s = actions.create_task({ content = "leaf S", path = path })
sync.sync_todo_file(path)
local ok_s = deleter.delete(s.id)
check("forbid allows leaf", ok_s == true)
check("forbid: leaf gone", core.get_task(s.id) == nil)

---------------------------------------------------------------------
-- 2) promote：删父，子提升一级并挂到祖父
---------------------------------------------------------------------
local ok_p, res_p = deleter.delete(p.id, { mode = "promote" })
check("promote ok", ok_p == true, vim.inspect(res_p))
check("promote: parent gone", core.get_task(p.id) == nil)
check("promote: c1 kept", core.get_task(c1.id) ~= nil)
check("promote: c2 kept", core.get_task(c2.id) ~= nil)
check("promote: parent line gone", not any_line_has(p.id))
check("promote: c1 line kept", any_line_has(c1.id))
check("promote: c1->grand G", relation.get_parent_id(c1.id) == g.id, vim.inspect(relation.get_parent_id(c1.id)))
check("promote: c2->grand G", relation.get_parent_id(c2.id) == g.id)
check("promote: c1 indent lifted", indent_of(c1.id) == p_indent, tostring(indent_of(c1.id)) .. "/" .. tostring(p_indent))

---------------------------------------------------------------------
-- 3) cascade：删父，整棵子树消失
---------------------------------------------------------------------
local p2 = actions.create_task({ content = "parent P2", path = path, parent_id = g.id })
local d1 = actions.create_task({ content = "child D1", path = path, parent_id = p2.id })
sync.sync_todo_file(path)
check("setup2: d1->p2", relation.get_parent_id(d1.id) == p2.id)

local ok_c, res_c = deleter.delete(p2.id, { mode = "cascade" })
check("cascade ok", ok_c == true, vim.inspect(res_c))
check("cascade: parent gone", core.get_task(p2.id) == nil)
check("cascade: child gone", core.get_task(d1.id) == nil)
check("cascade: parent line gone", not any_line_has(p2.id))
check("cascade: child line gone", not any_line_has(d1.id))
check("cascade: no dangling parent", relation.get_parent_id(d1.id) == nil)

---------------------------------------------------------------------
-- 4) 非法 mode
---------------------------------------------------------------------
local ok_bad, res_bad = deleter.delete(g.id, { mode = "bogus" })
check("invalid mode rejected", ok_bad == false and res_bad.error == "invalid_mode", vim.inspect(res_bad))

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
