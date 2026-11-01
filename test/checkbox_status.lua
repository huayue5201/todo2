-- checkbox 与终态的一致性（回归测试，headless 自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-checkbox-xdg nvim --headless -u NONE -l test/checkbox_status.lua
--
-- 背景：文件是真相源，但 sync 过去只回写 content / tags / due / start，
-- 手改 `- [ ]` → `- [x]` 后 store 仍是 todo：渲染、日历、统计全看不到"已完成"，
-- timestamps.completed 永远是 nil。反向把 `[x]` 改回 `[ ]` 也退不出终态。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-checkbox-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-checkbox-proj"), "rf")

require("todo2").setup({})

local actions = require("todo2.ai.actions")
local core = require("todo2.store.task.core")
local sync = require("todo2.core.sync")
local status_domain = require("todo2.core.status")

local fails, total = 0, 0
local function check(name, cond, extra)
	total = total + 1
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

--- 把文件里的任务行换成指定的 checkbox（走 buffer，因为 sync 优先读已加载的 buffer）
local function set_checkbox(path, id, box)
	local bufnr = vim.fn.bufadd(path)
	require("todo2.utils.buffer").ensure_loaded(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for i, line in ipairs(lines) do
		-- 状态已经落盘后行首标记会变成 `doing:`/`completed:` 等，按 id 定位
		if line:find(":" .. id, 1, true) then
			lines[i] = line:gsub("%- %[[ x>-]%]", "- [" .. box .. "]", 1)
		end
	end
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	sync.sync_todo_file(path)
end

local f = actions.create_todo_file("cbtest")
local a = actions.create_task({ content = "会被手改 checkbox 的任务", path = f.path })
check("created with default status", core.get_task(a.id).core.status == "todo", core.get_task(a.id).core.status)

-- [ ] → [x]
set_checkbox(f.path, a.id, "x")
local t = core.get_task(a.id)
check("checkbox [x] sets completed", t.core.status == "completed", t.core.status)
check("checkbox [x] records completed timestamp", type(t.timestamps.completed) == "number" and t.timestamps.completed > 0, t.timestamps.completed)

-- [x] → [ ]：勾掉后必须退出完成态，且清掉完成时间
-- （`[>]` 归档不在这里测：归档由所在区域决定，见 test/archive_render.lua）
set_checkbox(f.path, a.id, " ")
t = core.get_task(a.id)
check("checkbox [ ] leaves the terminal state", t.core.status == "todo", t.core.status)
check("leaving terminal clears completed", t.timestamps.completed == nil, t.timestamps.completed)

-- 活跃状态不被 [ ] 覆盖（[ ] 只说明"不是终态"）
status_domain.set_status(a.id, "doing", "test")
set_checkbox(f.path, a.id, " ")
check("checkbox [ ] keeps the active status", core.get_task(a.id).core.status == "doing", core.get_task(a.id).core.status)

-- 再完成一次，确认与手改顺序无关
set_checkbox(f.path, a.id, "x")
check("status still completes after being doing", core.get_task(a.id).core.status == "completed", core.get_task(a.id).core.status)

print(fails == 0 and string.format("ALL PASS (%d checks)", total) or string.format("%d/%d FAILED", fails, total))
if fails > 0 then
	os.exit(1)
end
