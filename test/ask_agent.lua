-- ask-agent 桥接（headless，自包含）。
-- 运行：./scripts/test.sh ask_agent
--
-- ask-agent 用假模块替身：只验证 todo2 这侧的组装、锚点、关联键与状态回写。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-ask-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)

require("todo2").setup({})
vim.fn.delete(require("todo2.utils.project").current().dir, "rf")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

-- 假 ask-agent：记下 send 参数，暴露 on() 让我们手动触发完成事件
local sent, handlers = {}, {}
package.loaded["ask_agent"] = {
	send = function(text, opts)
		sent[#sent + 1] = { text = text, opts = opts }
		return true
	end,
	on = function(event, fn)
		handlers[event] = fn
		return function() end
	end,
}

local actions = require("todo2.ai.actions")
local bridge = require("todo2.integrations.ask_agent")
local core = require("todo2.store.task.core")

local codefile = projdir .. "/code.lua"
vim.fn.writefile({ "local x = 1", "return x" }, codefile)

local f = actions.create_todo_file("ask")
local task = actions.create_task({ content = "wire the bridge", path = f.path, anchor = { path = codefile, line = 2 } })

check("ask-agent visible", bridge.available())

-- TODO 文件里：光标在任务行上拿到 id，发送带 correlation 与锚点
vim.cmd.edit(vim.fn.fnameescape(f.path))
vim.wait(200, function()
	return false
end)
local lnum
for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
	if l:find(task.id, 1, true) then
		lnum = i
		break
	end
end
check("task line found", lnum ~= nil)
vim.api.nvim_win_set_cursor(0, { lnum, 0 })
check("task id under cursor in TODO file", bridge.task_at_cursor() == task.id, tostring(bridge.task_at_cursor()))

local ok = bridge.ask()
check("ask() sends", ok and #sent == 1, tostring(ok))
local msg = sent[1] or { text = "", opts = {} }
check("message carries the task", msg.text:find(task.id, 1, true) ~= nil)
check("message carries the code", msg.text:find("return x", 1, true) ~= nil)
check(
	"correlation key",
	msg.opts.correlation and msg.opts.correlation.plugin == "todo2" and msg.opts.correlation.key == task.id
)
check("correlation shows the task id", msg.opts.correlation.label == task.id, vim.inspect(msg.opts.correlation))
check(
	"correlation keeps the title",
	msg.opts.correlation.title == "wire the bridge",
	tostring(msg.opts.correlation.title)
)
check("anchor line", msg.opts.anchor and msg.opts.anchor.line == 2, vim.inspect(msg.opts.anchor))
check("anchor resolves to the file", msg.opts.anchor.bufname == vim.api.nvim_buf_get_name(vim.fn.bufnr(codefile)))
-- 多个可用实例时不猜：让 ask-agent 弹选择器（只有一个同项目实例时它直接发出去）
check("asks before guessing the instance", msg.opts.pick == true, tostring(msg.opts.pick))
check("send result is reported back", type(msg.opts.on_sent) == "function", type(msg.opts.on_sent))

-- 代码侧：光标在这一行的任务上
vim.cmd.edit(vim.fn.fnameescape(codefile))
vim.wait(200, function()
	return false
end)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
check("task id under cursor in code", bridge.task_at_cursor() == task.id, tostring(bridge.task_at_cursor()))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check("line without a task", bridge.task_at_cursor() == nil, tostring(bridge.task_at_cursor()))

-- 显式目标透传
bridge.ask(task.id, { backend = "pi", target = "agent-7" })
local explicit = sent[#sent]
check("backend passthrough", explicit.opts.backend == "pi")
check("target passthrough", explicit.opts.target == "agent-7")
check("explicit target skips the picker", explicit.opts.pick == false, tostring(explicit.opts.pick))

-- 关掉 pick_target 就退回确定性匹配（不弹选择器）
bridge.pick_target = false
bridge.ask(task.id)
check("pick_target off sends straight away", sent[#sent].opts.pick == false, tostring(sent[#sent].opts.pick))
bridge.pick_target = true

-- 回写：agent 完成 → 任务 completed
bridge.setup()
check("done handler registered", handlers.done ~= nil)
handlers.done({ tasks = { { status = "done", correlation = { plugin = "todo2", key = task.id } } } })
check("task completed", core.get_task(task.id).core.status == "completed", core.get_task(task.id).core.status)

-- 推断的完成默认不回写（一个空闲探测不该把任务标完成）
local inferred = actions.create_task({ content = "inferred only", path = f.path })
local done_rec = {
	key = "fake:inferred",
	source = "heuristic",
	tasks = { { status = "done", ts = 1, correlation = { plugin = "todo2", key = inferred.id } } },
}
handlers.done(done_rec)
check(
	"heuristic done ignored by default",
	core.get_task(inferred.id).core.status ~= "completed",
	core.get_task(inferred.id).core.status
)
bridge.complete_heuristic = true
handlers.done(done_rec)
check(
	"heuristic done honoured when opted in",
	core.get_task(inferred.id).core.status == "completed",
	core.get_task(inferred.id).core.status
)
bridge.complete_heuristic = false

-- auto_complete = false 时完全不动状态
bridge.auto_complete = false
local quiet = actions.create_task({ content = "leave me alone", path = f.path })
handlers.done({ tasks = { { status = "done", ts = 2, correlation = { plugin = "todo2", key = quiet.id } } } })
check(
	"auto_complete off keeps status",
	core.get_task(quiet.id).core.status ~= "completed",
	core.get_task(quiet.id).core.status
)
bridge.auto_complete = true

-- 同一轮重复事件只通知一次，不再二次 set_status（用计数确认）
local once = actions.create_task({ content = "say it once", path = f.path })
local calls = 0
local real_set = actions.set_status
actions.set_status = function(id, status)
	calls = calls + 1
	return real_set(id, status)
end
local same = { tasks = { { status = "done", ts = 9, correlation = { plugin = "todo2", key = once.id } } } }
handlers.done(same)
handlers.done(same)
actions.set_status = real_set
check("same turn completes once", calls == 1, tostring(calls))

-- 别人的关联键不动
local other = actions.create_task({ content = "not yours", path = f.path })
handlers.done({ tasks = { { status = "done", correlation = { plugin = "other", key = other.id } } } })
check("foreign correlation ignored", core.get_task(other.id).core.status ~= "completed")

-- ask-agent 不在时安静失败
package.loaded["ask_agent"] = nil
local blocked, err = bridge.ask(task.id)
check("no ask-agent: reports, does not throw", blocked == false and type(err) == "string", tostring(err))

if fails == 0 then
	print("ALL PASS")
	vim.cmd("qa!")
else
	print(fails .. " FAILED")
	vim.cmd("cq!")
end
