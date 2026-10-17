-- MCP standalone 模式契约测试（headless，自包含，无需任何活着的 nvim）。
-- 运行：nvim --headless -u NONE -l test/mcp_standalone.lua
--
-- 覆盖：没有活 nvim 时 initialize / tools/list / create_todo_file / note /
--       带真实代码锚点的 task / list(+structuredContent) / search / info /
--       context / update / archive / unarchive / delete / 跨进程持久化 /
--       TODO2_PROJECT_DIR 覆盖项目目录。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local nvim = vim.v.progpath
local bridge = root .. "/mcp/todo2-mcp.lua"

local projdir = "/tmp/todo2-mcp-standalone-proj"
local home = "/tmp/todo2-mcp-standalone-home"
local xdg = "/tmp/todo2-mcp-standalone-xdg"
vim.fn.delete(projdir, "rf")
vim.fn.delete(home, "rf")
vim.fn.delete(xdg, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.mkdir(home, "p")

-- 供带锚点任务使用的真实代码文件
vim.fn.writefile({
	"local M = {}",
	"function M.greet(name)",
	"\treturn 'hi ' .. name",
	"end",
	"return M",
}, projdir .. "/foo.lua")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

--- 启动 standalone MCP，依次发请求，返回各响应。
--- 关键：env 里带 TODO2_MCP_STANDALONE=1，且隔离 HOME / XDG_DATA_HOME，
--- 全程不设 TODO2_NVIM —— 证明无需任何活着的 nvim。
local function run(env, requests, opts)
	local out = {}
	local job = vim.fn.jobstart({ nvim, "--headless", "-u", "NONE", "-l", bridge }, {
		env = env,
		cwd = opts and opts.cwd or nil,
		on_stdout = function(_, data)
			for _, l in ipairs(data or {}) do
				if l ~= "" then
					out[#out + 1] = l
				end
			end
		end,
	})
	local res = {}
	for i, rq in ipairs(requests) do
		vim.fn.chansend(job, vim.json.encode({ jsonrpc = "2.0", id = i, method = rq[1], params = rq[2] or {} }) .. "\n")
		local deadline = vim.loop.now() + 20000
		while #out < 1 and vim.loop.now() < deadline do
			vim.wait(50)
		end
		local line = table.remove(out, 1)
		res[#res + 1] = line and vim.json.decode(line) or nil
	end
	vim.fn.jobstop(job)
	return res
end

local function base_env()
	return { TODO2_MCP_STANDALONE = "1", HOME = home, XDG_DATA_HOME = xdg }
end

local function txt(r)
	return r and r.result and r.result.content and r.result.content[1] and r.result.content[1].text
end

-- Run 1：全新项目，创建文件 / 无锚点 note / 带锚点 task，读回
local res = run(base_env(), {
	{ "initialize", { protocolVersion = "2025-06-18", capabilities = {} } },
	{ "tools/list", {} },
	{ "tools/call", { name = "task_create", arguments = { action = "file", name = "main" } } },
	{ "tools/call", { name = "task_create", arguments = { action = "note", content = "standalone alpha" } } },
	{ "tools/call", {
		name = "task_create",
		arguments = {
			action = "task",
			content = "anchored beta",
			anchor = { path = projdir .. "/foo.lua", line = 2 },
		},
	} },
	{ "tools/call", { name = "task_query", arguments = { action = "list" } } },
	{ "tools/call", { name = "task_query", arguments = { action = "search", query = "alpha" } } },
	{ "tools/call", { name = "task_query", arguments = { action = "info" } } },
}, { cwd = projdir })

check("initialize", res[1] and res[1].result and res[1].result.serverInfo)

local names = {}
for _, t in ipairs((res[2].result or {}).tools or {}) do
	names[t.name] = true
end
check("tools/list has 5 tools", names.task_query and names.task_create and names.task_update and names.task_link and names.task_remove)
check("task_create/file", txt(res[3]) and txt(res[3]):find("main.todo.md") ~= nil, txt(res[3]))

local note_id, anchored_id
do
	local d = vim.json.decode(txt(res[4]) or "")
	note_id = d and d.id
end
do
	local d = vim.json.decode(txt(res[5]) or "")
	anchored_id = d and d.id
end
check("task_create/note", note_id ~= nil, txt(res[4]))
check("task_create/task anchored", anchored_id ~= nil and txt(res[5]):find('"state":"ok"') ~= nil, txt(res[5]))
check("task_query/list contains alpha", txt(res[6]) and txt(res[6]):find("standalone alpha") ~= nil, txt(res[6]))
check("task_query/list structured", res[6] and res[6].result and res[6].result.structuredContent ~= nil and res[6].result.structuredContent.items ~= nil)
check("task_query/search", txt(res[7]) and txt(res[7]):find("standalone alpha") ~= nil, txt(res[7]))
check("task_query/info project", txt(res[8]) and txt(res[8]):find("todo2%-mcp%-standalone%-proj") ~= nil, txt(res[8]))

-- Run 2：全新进程（验证从磁盘对账 + facts 持久化），读写同一项目
local res2 = run(base_env(), {
	{ "tools/call", { name = "task_query", arguments = { action = "list" } } },
	{ "tools/call", { name = "task_query", arguments = { action = "context", id = note_id } } },
	{ "tools/call", { name = "task_update", arguments = { action = "content", id = note_id, content = "renamed gamma" } } },
	{ "tools/call", { name = "task_query", arguments = { action = "search", query = "renamed" } } },
	{ "tools/call", { name = "task_remove", arguments = { action = "archive", id = note_id } } },
	{ "tools/call", { name = "task_remove", arguments = { action = "unarchive", id = note_id } } },
	{ "tools/call", { name = "task_remove", arguments = { action = "delete", id = note_id } } },
}, { cwd = projdir })

check("persistence: list after restart", txt(res2[1]) and txt(res2[1]):find("standalone alpha") ~= nil, txt(res2[1]))
check("task_query/context", txt(res2[2]) and txt(res2[2]):find("# Task " .. tostring(note_id)) ~= nil, txt(res2[2]))
check("task_update/content", txt(res2[3]) and txt(res2[3]):find("renamed gamma") ~= nil, txt(res2[3]))
check("search updated", txt(res2[4]) and txt(res2[4]):find("renamed gamma") ~= nil, txt(res2[4]))
check("task_remove/archive", txt(res2[5]) and txt(res2[5]):find("archived") ~= nil, txt(res2[5]))
check("task_remove/unarchive", txt(res2[6]) and txt(res2[6]):find("unarchived") ~= nil, txt(res2[6]))
check("task_remove/delete", txt(res2[7]) and txt(res2[7]):find("deleted") ~= nil, txt(res2[7]))

-- Run 3：cwd 在别处，用 TODO2_PROJECT_DIR 指定项目目录
local env3 = base_env()
env3.TODO2_PROJECT_DIR = projdir
local res3 = run(env3, {
	{ "tools/call", { name = "task_query", arguments = { action = "info" } } },
}, { cwd = "/tmp" })
check("TODO2_PROJECT_DIR override", txt(res3[1]) and txt(res3[1]):find("todo2%-mcp%-standalone%-proj") ~= nil, txt(res3[1]))

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
