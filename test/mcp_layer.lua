-- MCP 桥契约测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/mcp_layer.lua
--
-- 拉起 test/mcp_server.lua 作为活实例，再以 stdio 驱动 mcp/todo2-mcp.lua，覆盖：
--   initialize / tools/list / list_tasks(+structuredContent) / get_project_info /
--   search_tasks / create_note / update_content / archive_task / unarchive_task /
--   delete_task / 只读模式拦截 / TODO2_PROJECT 多实例路由。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local nvim = vim.v.progpath
local bridge = root .. "/mcp/todo2-mcp.lua"
local server = root .. "/test/mcp_server.lua"
local ready = "/tmp/todo2-mcp-test.ready"

vim.fn.delete(ready)

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

-- 启动 fixture 服务端
vim.fn.jobstart({ nvim, "--headless", "-u", "NONE", "-l", server }, { stdout_buffered = false })
do
	local deadline = vim.loop.now() + 30000
	while vim.fn.filereadable(ready) == 0 and vim.loop.now() < deadline do
		vim.wait(50)
	end
end
check("server ready", vim.fn.filereadable(ready) == 1)

local addr = vim.fn.readfile(ready)[1]

--- 以给定环境启动桥，依次发请求，返回各响应的 text。
local function run(env, requests)
	local out = {}
	local job = vim.fn.jobstart({ nvim, "--headless", "-u", "NONE", "-l", bridge }, {
		env = env,
		on_stdout = function(_, data)
			for _, l in ipairs(data or {}) do
				if l ~= "" then
					out[#out + 1] = l
				end
			end
		end,
	})
	local id = 0
	local res = {}
	for _, rq in ipairs(requests) do
		id = id + 1
		vim.fn.chansend(job, vim.json.encode({ jsonrpc = "2.0", id = id, method = rq[1], params = rq[2] or {} }) .. "\n")
		local deadline = vim.loop.now() + 15000
		while #out < 1 and vim.loop.now() < deadline do
			vim.wait(50)
		end
		local line = table.remove(out, 1)
		res[#res + 1] = line and vim.json.decode(line) or nil
	end
	vim.fn.jobstop(job)
	return res
end

local function txt(r)
	return r and r.result and r.result.content and r.result.content[1] and r.result.content[1].text
end

-- 全量契约
local res = run({ TODO2_NVIM = addr }, {
	{ "initialize", { protocolVersion = "2025-06-18", capabilities = {} } },
	{ "tools/list", {} },
	{ "tools/call", { name = "list_tasks", arguments = {} } },
	{ "tools/call", { name = "get_project_info", arguments = {} } },
	{ "tools/call", { name = "search_tasks", arguments = { query = "alpha" } } },
	{ "tools/call", { name = "create_note", arguments = { content = "note from mcp beta" } } },
})

check("initialize", res[1] and res[1].result and res[1].result.serverInfo)

local names = {}
for _, t in ipairs((res[2].result or {}).tools or {}) do
	names[t.name] = true
end
for _, n in ipairs({
	"list_tasks", "get_task_tree", "get_task_context", "search_tasks", "get_project_info",
	"create_task", "create_task_tree", "create_note", "update_content", "delete_task",
	"archive_task", "unarchive_task", "verify_anchors", "set_status", "set_tags",
}) do
	check("has tool " .. n, names[n] == true)
end

check("list_tasks", txt(res[3]) and txt(res[3]):find("bridge alpha task") ~= nil)
check("list_tasks structured", res[3] and res[3].result and res[3].result.structuredContent ~= nil)
check("get_project_info", txt(res[4]) and txt(res[4]):find("todo2%-mcp%-test%-proj") ~= nil)
check("search_tasks", txt(res[5]) and txt(res[5]):find("bridge alpha task") ~= nil)

local note_id
do
	local ok, dec = pcall(vim.json.decode, txt(res[6]) or "")
	if ok and dec then
		note_id = dec.id
	end
end
check("create_note", note_id ~= nil, txt(res[6]))

local res2 = run({ TODO2_NVIM = addr }, {
	{ "tools/call", { name = "update_content", arguments = { id = note_id, content = "note renamed gamma" } } },
	{ "tools/call", { name = "archive_task", arguments = { id = note_id } } },
	{ "tools/call", { name = "unarchive_task", arguments = { id = note_id } } },
	{ "tools/call", { name = "delete_task", arguments = { id = note_id } } },
})
check("update_content", txt(res2[1]) and txt(res2[1]):find("note renamed gamma") ~= nil, txt(res2[1]))
check("archive_task", txt(res2[2]) and txt(res2[2]):find("archived") ~= nil, txt(res2[2]))
check("unarchive_task", txt(res2[3]) and txt(res2[3]):find("unarchived") ~= nil, txt(res2[3]))
check("delete_task", txt(res2[4]) and txt(res2[4]):find("deleted") ~= nil, txt(res2[4]))

-- 只读模式
local ro = run({ TODO2_NVIM = addr, TODO2_MCP_READONLY = "1" }, {
	{ "tools/call", { name = "create_note", arguments = { content = "blocked" } } },
	{ "tools/call", { name = "list_tasks", arguments = {} } },
})
check("readonly blocks write", txt(ro[1]) and txt(ro[1]):lower():find("read%-only") ~= nil, txt(ro[1]))
check("readonly allows read", txt(ro[2]) and txt(ro[2]):find("bridge alpha task") ~= nil)

-- 多实例项目路由
local rt = run({ TODO2_PROJECT = "todo2-mcp-test-proj" }, {
	{ "tools/call", { name = "get_project_info", arguments = {} } },
})
check("TODO2_PROJECT routing", txt(rt[1]) and txt(rt[1]):find("todo2%-mcp%-test%-proj") ~= nil, txt(rt[1]))

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
