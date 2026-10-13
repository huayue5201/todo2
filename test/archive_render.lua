-- 归档/反归档时的代码端渲染回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-archive-render-xdg nvim --headless -u NONE -l test/archive_render.lua
--
-- 回归点：归档任务从主库删除后，代码缓冲区上它的标记必须被清掉；
-- 反归档后标记要重新出现。历史上归档事件只带了 TODO 文件路径，
-- 且任务已不在主库、events 反查不到代码路径，导致代码端残留标记。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-archive-render-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir .. "/src", "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-archive-render-proj"), "rf")

local code = projdir .. "/src/lib.rs"
vim.fn.writefile({ "pub fn alpha() {", "    1", "}" }, code)

require("todo2").setup({})

local actions = require("todo2.ai.actions")
local core = require("todo2.store.task.core")
local index = require("todo2.store.index")
local code_render = require("todo2.render.code_render")
local core_archive = require("todo2.core.archive")
local constants = require("todo2.constants")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local f = actions.create_todo_file("arch")
check("create todo file", f and f.path ~= nil, f and f.path)

local r = actions.create_task({
	content = "anchored task",
	path = f.path,
	anchor = { path = code, line = 1 },
})
check("create anchored task", r and r.id ~= nil, r and r.id)
local id = r.id

local cb = vim.fn.bufadd(code)
vim.fn.bufload(cb)
local ns = constants.ns("code_render")
local function marks()
	return #vim.api.nvim_buf_get_extmarks(cb, ns, 0, -1, {})
end

-- 先让任务创建事件（会刷新代码文件）处理完，再渲染，避免创建事件掩盖归档路径。
vim.wait(300, function()
	return false
end)
code_render.render_file(cb)
vim.wait(100, function()
	return false
end)
check("rendered one marker before archive", marks() == 1, marks())

-- 归档：main 库删除 + TODO 行移除 + 事件 -> 代码标记应被清除
local ok = core_archive.archive_task_group(id)
check("archive succeeded", ok == true, ok)
check("task removed from main store", core.get_task(id) == nil)
vim.wait(500, function()
	return false
end)
check("code marker cleared after archive", marks() == 0, marks())
check("code index empty after archive", #index.find_code_links_by_file(code) == 0)

-- 反归档：代码标记应重新出现
local ok2 = core_archive.unarchive_task_group({ id })
check("unarchive succeeded", ok2 == true, ok2)
check("task back in main store", core.get_task(id) ~= nil)
vim.wait(500, function()
	return false
end)
check("code marker restored after unarchive", marks() == 1, marks())

if fails == 0 then
	print("ALL PASS")
else
	print("FAILS " .. fails)
end
vim.cmd("qa!")
