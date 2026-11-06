-- 跨项目任务关系（@rel）与全局视图索引测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/global_rel.lua
--
-- 覆盖：行内 @rel 的解析/写回、store 的 core.rels、只读跨项目索引的反向边与
-- 悬空引用、全局视图的分组渲染、:TodoRel 的 add/remove 语义，以及跨项目跳转
-- （新 tab + tcd，保证对方的 store 不会被写进当前项目）。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local proj = "/tmp/todo2-global-rel-proj"
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

-- 另一个项目：手写清单 + 一个引用当前项目的任务，验证反向边。
local other_name = "todo2-global-rel-other--deadbeef"
local other_root = "/tmp/todo2-global-rel-other"
local other_dir = project_utils.vault_root() .. "/" .. other_name
vim.fn.delete(other_dir, "rf")
vim.fn.delete(other_root, "rf")
vim.fn.mkdir(other_dir, "p")
vim.fn.mkdir(other_root, "p")
vim.fn.writefile({
	vim.json.encode({ name = other_name, label = "other", identity = "git:other", root = other_root }),
}, other_dir .. "/.project.json")
vim.fn.writefile({
	"- [ ] remote @id(bbbbbb) @rel(" .. me.name .. "/aaaaaa)",
	"- [x] done remote @id(eeeeee)",
}, other_dir .. "/b.todo.md")

local todo_path = me.dir .. "/a.todo.md"
vim.fn.writefile({
	"- [ ] local task @id(aaaaaa) @rel(blocks:" .. other_name .. "/bbbbbb) @rel(" .. other_name .. "/cccccc) #x",
	"- [ ] plain @id(dddddd) @rel(nope)",
}, todo_path)

require("todo2.core.sync").sync_todo_file(todo_path)
local core = require("todo2.store.task.core")
local task = core.get_task("aaaaaa")
check("rels synced into store", task and #task.core.rels == 2, task and vim.inspect(task.core.rels))
check("invalid @rel dropped", task and vim.tbl_contains(task.core.rels, "nope") == false)
check("rel token canonical", task and task.core.rels[1] == "blocks:" .. other_name .. "/bbbbbb")

require("todo2.utils.task_line").rewrite("aaaaaa")
local line = vim.fn.readfile(todo_path)[1]
check("rewrite preserves rels", line:find("@rel(blocks:" .. other_name .. "/bbbbbb)", 1, true) ~= nil, line)
check("rewrite keeps tags last", line:find("#x", 1, true) > line:find("@rel(", 1, true), line)

local index = require("todo2.global.index")
local data = index.scan()
local local_entry = data.by_qref[me.name .. "/aaaaaa"]
local remote_entry = data.by_qref[other_name .. "/bbbbbb"]
check("scan finds local", local_entry ~= nil)
check("scan finds remote", remote_entry ~= nil)
check("outgoing edges", local_entry and #local_entry.outgoing == 2)
check("reverse edge blocks the remote task", remote_entry and remote_entry.blocked == 1)
check("local task is not blocked", local_entry and local_entry.blocked == 0)
check("dangling reference counted", local_entry and local_entry.dangling == 1, local_entry and local_entry.dangling)
check("completed task is inactive", (function()
	for _, e in ipairs(data.entries) do
		if e.id == "eeeeee" then
			return not e.active
		end
	end
	return false
end)())

local header, lines, rows = index.render_lines(data)
check("render header counts", header:find("active task") ~= nil and header:find("project") ~= nil, header)
check("render groups by project", #lines > 2)
check("render maps every non-blank line", (function()
	for i, l in ipairs(lines) do
		if l ~= "" and rows[i] == nil then
			return false
		end
	end
	return true
end)())
check("render hides completed tasks", (function()
	for _, l in ipairs(lines) do
		if l:find("done remote", 1, true) then
			return false
		end
	end
	return true
end)())

local rel = require("todo2.handlers.rel")
local rels, err = rel.rels_for_id("aaaaaa", "add", { "relates:" .. other_name .. "/bbbbbb" })
check("add relation", rels ~= nil, err)
check("same qref dedups across kinds", rels and #rels == 3, rels and vim.inspect(rels))
rels = rel.rels_for_id("aaaaaa", "add", { "blocks:" .. other_name .. "/cccccc" })
check("different kind is a new edge", rels and #rels == 4, rels and vim.inspect(rels))
rels = rel.rels_for_id("aaaaaa", "remove", { other_name .. "/bbbbbb" })
check("remove by qref drops all kinds", rels and #rels == 2, rels and vim.inspect(rels))
rels, err = rel.rels_for_id("aaaaaa", "add", { "nope" })
check("invalid ref rejected", rels == nil and err ~= nil, err)
rels, err = rel.rels_for_id("aaaaaa", "add", { me.name .. "/aaaaaa" })
check("self reference rejected", rels == nil and err ~= nil, err)

-- 选择器模式：:TodoRel 无参数 / 抽屉 L 打开，<CR> 增删边、b 切换类型。
local global_ui = require("todo2.ui.global")
local function key_of(buf, lhs)
	local cb
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if m.lhs == lhs then
			cb = m.callback
		end
	end
	return cb
end
local function row_of(buf, needle)
	for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if l:find(needle, 1, true) then
			return i, l
		end
	end
end

global_ui.open_pick({ id = "aaaaaa", content = "local task", rels = core.get_task("aaaaaa").core.rels })
local pb = vim.fn.bufnr("todo2://global")
local prow, pline = row_of(pb, "remote")
check("picker lists other projects", prow ~= nil, pline)
check("picker marks existing edges", pline and pline:find("✔", 1, true) == nil)
local pcr, pspace = key_of(pb, "<CR>"), key_of(pb, " ")
check("picker maps <CR> and <Space>", pcr ~= nil and pspace ~= nil)

local function press_space()
	prow = row_of(pb, "remote")
	vim.api.nvim_win_set_cursor(0, { prow, 0 })
	pspace()
end

press_space()
local rels_now = core.get_task("aaaaaa").core.rels
check("picker adds an edge", vim.tbl_contains(rels_now, other_name .. "/bbbbbb"), vim.inspect(rels_now))
local _, marked = row_of(pb, "remote")
check("picker shows the ✔ mark", marked and marked:find("✔", 1, true) ~= nil)

press_space()
check("picker removes it again", not vim.tbl_contains(core.get_task("aaaaaa").core.rels, other_name .. "/bbbbbb"), vim.inspect(core.get_task("aaaaaa").core.rels))

key_of(pb, "b")()
press_space()
check("picker b switches the kind", vim.tbl_contains(core.get_task("aaaaaa").core.rels, "blocks:" .. other_name .. "/bbbbbb"), vim.inspect(core.get_task("aaaaaa").core.rels))
key_of(pb, "q")()
check("picker closes", vim.fn.bufnr("todo2://global") == -1)

vim.cmd("edit " .. vim.fn.fnameescape(todo_path))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("TodoRel +blocks:" .. other_name .. "/cccccc")
check(":TodoRel writes the line", vim.fn.readfile(todo_path)[1]:find("@rel(blocks:" .. other_name .. "/cccccc)", 1, true) ~= nil, vim.fn.readfile(todo_path)[1])
check(":TodoRel updates the store", vim.tbl_contains(core.get_task("aaaaaa").core.rels, "blocks:" .. other_name .. "/cccccc"))

vim.cmd("TodoGlobal")
local gbuf = vim.fn.bufnr("todo2://global")
check(":TodoGlobal opens", gbuf > 0)
local target
for i, l in ipairs(vim.api.nvim_buf_get_lines(gbuf, 0, -1, false)) do
	if l:find("remote", 1, true) and not l:find("done remote", 1, true) then
		target = i
	end
end
check("global lists the other project's task", target ~= nil)
if target then
	vim.api.nvim_win_set_cursor(0, { target, 0 })
	local cr
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(gbuf, "n")) do
		if m.lhs == "<CR>" then
			cr = m.callback
		end
	end
	check("global maps <CR>", cr ~= nil)
	if cr then
		cr()
		check("jump opens the other project's file", vim.api.nvim_buf_get_name(0) == other_dir .. "/b.todo.md", vim.api.nvim_buf_get_name(0))
		check("jump switches cwd", vim.fn.resolve(vim.fn.getcwd()) == vim.fn.resolve(other_root), vim.fn.getcwd())
		check("jump places the cursor", vim.fn.line(".") == 1)
		check("global view closes after the jump", vim.fn.bufnr("todo2://global") == -1)
	end
end

-- 过滤：`f` 边打边过滤、`F` 清除（vault 里项目多时找目标靠它）
vim.cmd("TodoGlobal")
gbuf = vim.fn.bufnr("todo2://global")
key_of(gbuf, "f")()
local fbuf = vim.api.nvim_get_current_buf()
check("filter prompt opens", vim.bo[fbuf].filetype == "todo2filterprompt", vim.bo[fbuf].filetype)
vim.api.nvim_buf_set_lines(fbuf, 0, 1, false, { "remote" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = fbuf })
check("filter narrows the list", row_of(gbuf, "remote") ~= nil and row_of(gbuf, "local task") == nil)
local fcr
for _, m in ipairs(vim.api.nvim_buf_get_keymap(fbuf, "i")) do
	if m.lhs == "<CR>" then
		fcr = m.callback
	end
end
check("filter prompt maps <CR>", fcr ~= nil)
fcr()
check("filter survives submit", row_of(gbuf, "local task") == nil)
check("header shows the filter", row_of(gbuf, "/remote") ~= nil)
key_of(gbuf, "F")()
check("F clears the filter", row_of(gbuf, "local task") ~= nil)
key_of(gbuf, "q")()

vim.fn.delete(me.dir, "rf")
vim.fn.delete(other_dir, "rf")
vim.fn.delete(other_root, "rf")
vim.fn.delete(proj, "rf")
print(fails == 0 and "ALL OK" or ("FAILURES: " .. fails))
vim.cmd(fails == 0 and "qa!" or "cq")
