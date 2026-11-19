-- 状态切换只重绘一次（headless，自包含）。
-- 运行：./scripts/test.sh no_duplicate_render
--
-- 回归背景：切换状态时 line_edit 会把 checkbox 写回 TODO 文件并落盘，这次程序化写盘
-- 又触发 BufWritePost → todo_save 事件 → 所有关联文件再整体重绘一次，与 state_manager
-- 事件的首轮重绘相隔 ~30ms，视觉上就是闪烁。这里守住「一次切换 = 一次重绘」。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-no-dup-render"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(require("todo2.utils.project").current().dir, "rf")

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
local code_render = require("todo2.render.code_render")
local todo_render = require("todo2.render.todo_render")
local handlers = require("todo2.handlers")

---统计重绘次数（只看真正写 extmark 的入口）
local counts = {}
local per_buf = {}
local function spy(mod, name)
	local orig = mod[name]
	mod[name] = function(...)
		counts[name] = (counts[name] or 0) + 1
		local bufnr = ...
		if type(bufnr) == "number" then
			per_buf[bufnr] = (per_buf[bufnr] or 0) + 1
		end
		return orig(...)
	end
end
spy(code_render, "render_file")
spy(code_render, "render_changed")
spy(todo_render, "render")
spy(todo_render, "render_changed")

local function reset()
	for k in pairs(counts) do
		counts[k] = nil
	end
	for k in pairs(per_buf) do
		per_buf[k] = nil
	end
end

---同一 buffer 被重绘的最大次数（>1 即为重复刷新 = 闪烁）
local function max_per_buf()
	local n = 0
	for _, v in pairs(per_buf) do
		n = math.max(n, v)
	end
	return n
end

local function open(path)
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	vim.api.nvim_set_current_buf(buf)
	vim.wait(400)
end

---------------------------------------------------------------------
-- 1) 代码 / 笔记文件：<CR> 切换锚点任务的状态
---------------------------------------------------------------------
local md = projdir .. "/notes.md"
vim.fn.writefile({ "# notes", "", "target line", "more" }, md)

local todo = actions.create_todo_file("nd")
actions.create_task({ content = "anchored", path = todo.path, anchor = { path = md, line = 3 } })

open(md)
vim.api.nvim_win_set_cursor(0, { 3, 0 })
reset()
check("toggle on a linked code line is handled", handlers.toggle_task_status() == true)
vim.wait(600)
check("code buffer is redrawn once (no second refresh)", max_per_buf() == 1, vim.inspect(per_buf))

---------------------------------------------------------------------
-- 2) TODO 文件：<CR> 切换任务状态
---------------------------------------------------------------------
local todo2 = projdir .. "/t.todo.md"
vim.fn.writefile({ "# tasks", "- [ ] first task @id(aaa111) @created(1730000000)", "  body" }, todo2)
require("todo2.core.sync").sync_todo_file(todo2)

open(todo2)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
reset()
check("toggle in a TODO file is handled", handlers.toggle_task_status() == true)
vim.wait(600)
check("TODO file is redrawn once (no second refresh)", max_per_buf() == 1, vim.inspect(per_buf))
check("checkbox is written back", vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]:find("%[x%]") ~= nil)

print("")
if fails == 0 then
	print("ALL PASS")
else
	print(fails .. " FAILED")
	os.exit(1)
end
