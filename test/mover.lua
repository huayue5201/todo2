-- 任务复制/移动回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-mover-xdg nvim --headless -u NONE -l test/mover.lua
--
-- 覆盖抽屉 y(复制)/d(剪切)/p(粘贴) 背后的 mover 模块：
--   * 复制整棵子树到另一文件 → 生成新 id，结构与正文保留，源不动
--   * 剪切整棵子树到另一文件 → 保留原 id，代码锚点/描述/子关系随行迁移，源清空
--   * 禁止把任务复制进自己的子树；空寄存器粘贴失败

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-mover-test-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-mover-test-proj"), "rf")

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
local parser = require("todo2.core.parser")
local mover = require("todo2.task.mover")

---读取文件（已加载缓冲区优先）
local function lines_of(path)
	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function contains_id(path, id)
	for _, l in ipairs(lines_of(path)) do
		if l:find(id, 1, true) then
			return true
		end
	end
	return false
end

local function contains_text(path, txt)
	for _, l in ipairs(lines_of(path)) do
		if l == txt then
			return true
		end
	end
	return false
end

---把已加载缓冲区写回磁盘（避免后台孤儿回收误判尚未落盘的新文件）
local function flush(path)
	local bufnr = vim.fn.bufadd(path)
	vim.api.nvim_buf_call(bufnr, function()
		vim.cmd("silent! noautocmd write!")
	end)
end

local function parse(path)
	local tasks = parser.parse_lines(path, lines_of(path))
	local by_content = {}
	for _, t in ipairs(tasks) do
		by_content[t.content] = t
	end
	return tasks, by_content
end

local fa = actions.create_todo_file("from")
local fb = actions.create_todo_file("to")
local pathA, pathB = fa.path, fb.path
check("create file A", pathA ~= nil)
check("create file B", pathB ~= nil)

local p = actions.create_task({ content = "parent P", path = pathA })
local c1 = actions.create_task({ content = "child C1", path = pathA, parent_id = p.id })
local c2 = actions.create_task({ content = "child C2", path = pathA, parent_id = p.id })
local s = actions.create_task({ content = "sibling S", path = pathA })
check("tasks created", p and c1 and c2 and s)

-- 给 P 加正文块（复制/移动应随行带走）
local pbuf = vim.fn.bufadd(pathA)
vim.fn.bufload(pbuf)
local pline = core.get_task(p.id).locations.todo.line
vim.api.nvim_buf_set_lines(pbuf, pline, pline, false, { "  parent desc one", "  parent desc two" })
sync.sync_todo_file(pathA)

---------------------------------------------------------------------
-- 1. 复制整棵子树到 B
---------------------------------------------------------------------
mover.yank(p.id)
check("copy register set", mover.mode() == "copy")
check("copy ok", mover.paste(pathB, nil) == true)
check("copy register persists", mover.mode() == "copy")

local _, bByContent = parse(pathB)
local np = bByContent["parent P"]
local nc1 = bByContent["child C1"]
local nc2 = bByContent["child C2"]
check("B has copied parent", np ~= nil)
check("B has copied children", nc1 ~= nil and nc2 ~= nil)
check("copy has new ids", np and np.id ~= p.id and nc1 and nc1.id ~= c1.id)
check("copy keeps structure", np and nc1 and nc1.parent and nc1.parent.id == np.id)
check("copy keeps description", contains_text(pathB, "  parent desc one") and contains_text(pathB, "  parent desc two"))
check("source A untouched", contains_id(pathA, p.id) and contains_id(pathA, c1.id))
check("store: copied parent exists", np and core.get_task(np.id) ~= nil)
check("store: copied child relation", nc1 and relation.get_parent_id(nc1.id) == np.id)

-- 落盘，避免后续 vim.wait 触发的孤儿回收把未保存的副本误判为幽灵
flush(pathA)
flush(pathB)

---------------------------------------------------------------------
-- 2. 剪切带代码锚点的子树到 B
---------------------------------------------------------------------
local codepath = projdir .. "/sample.lua"
vim.fn.writefile({ "local function foo()", "  return 1", "end" }, codepath)
local m = actions.create_task({ content = "move M", path = pathA })
local n = actions.create_task({ content = "move child N", path = pathA, parent_id = m.id })
local linked = actions.link_code(m.id, codepath, 2)
check("M linked to code", linked ~= nil, vim.inspect(linked))
check("M code anchor before", core.get_task(m.id).locations.code ~= nil)

mover.cut(m.id)
check("cut register set", mover.mode() == "cut")
check("A no longer has M", not contains_id(pathA, m.id))
check("A no longer has N", not contains_id(pathA, n.id))

check("move ok", mover.paste(pathB, nil) == true)
check("cut register consumed", mover.mode() == nil)

local moved = core.get_task(m.id)
check("move keeps id", moved ~= nil)
check("move todo path -> B", moved and moved.locations.todo and moved.locations.todo.path == pathB)
check(
	"move keeps code anchor",
	moved and moved.locations.code and vim.uv.fs_realpath(moved.locations.code.path) == vim.uv.fs_realpath(codepath),
	moved and vim.inspect(moved.locations)
)
check("move keeps child relation", relation.get_parent_id(n.id) == m.id)
check("B has M line", contains_id(pathB, m.id))
check("B has N line", contains_id(pathB, n.id))

---------------------------------------------------------------------
-- 3. 边界
---------------------------------------------------------------------
mover.yank(p.id)
check("reject copy into own subtree", mover.paste(pathA, p.id) == false)
mover.clear()
check("empty register rejected", mover.paste(pathB, nil) == false)

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
