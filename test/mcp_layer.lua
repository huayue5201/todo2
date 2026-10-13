-- MCP 桥契约测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/mcp_layer.lua
--
-- 拉起 test/mcp_server.lua 作为活实例，再以 stdio 驱动 mcp/todo2-mcp.lua，覆盖：
--   initialize / tools/list / task_query(list,+structuredContent; info; search) /
--   task_create(note) / task_update(content) / task_remove(archive/unarchive/delete) /
--   只读模式拦截 / TODO2_PROJECT 多实例路由 / cwd 推导项目路由 /
--   TODO2_NVIM 死 socket 时存活性回落。

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
---@param opts table|nil { cwd = string }
local function run(env, requests, opts)
	local out = {}
	-- 空表在 jobstart 的 env 里会被当成数组而报 E475，需用 empty_dict
	if env ~= nil and next(env) == nil then
		env = vim.empty_dict()
	end
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
	local id = 0
	local res = {}
	for _, rq in ipairs(requests) do
		id = id + 1
		vim.fn.chansend(
			job,
			vim.json.encode({ jsonrpc = "2.0", id = id, method = rq[1], params = rq[2] or {} }) .. "\n"
		)
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
	{ "tools/call", { name = "task_query", arguments = { action = "list" } } },
	{ "tools/call", { name = "task_query", arguments = { action = "info" } } },
	{ "tools/call", { name = "task_query", arguments = { action = "search", query = "alpha" } } },
	{ "tools/call", { name = "task_create", arguments = { action = "note", content = "note from mcp beta" } } },
})

check("initialize", res[1] and res[1].result and res[1].result.serverInfo)

local names = {}
for _, t in ipairs((res[2].result or {}).tools or {}) do
	names[t.name] = true
end
for _, n in ipairs({ "task_query", "task_create", "task_update", "task_link", "task_remove" }) do
	check("has tool " .. n, names[n] == true)
end
check(
	"exactly 5 tools",
	(function()
		local c = 0
		for _ in pairs(names) do
			c = c + 1
		end
		return c == 5
	end)()
)

check("task_query/list", txt(res[3]) and txt(res[3]):find("bridge alpha task") ~= nil)
check("task_query/list structured", res[3] and res[3].result and res[3].result.structuredContent ~= nil)
check("task_query/info", txt(res[4]) and txt(res[4]):find("todo2%-mcp%-test%-proj") ~= nil)
check("task_query/search", txt(res[5]) and txt(res[5]):find("bridge alpha task") ~= nil)

local note_id
do
	local ok, dec = pcall(vim.json.decode, txt(res[6]) or "")
	if ok and dec then
		note_id = dec.id
	end
end
check("task_create/note", note_id ~= nil, txt(res[6]))

local res2 = run({ TODO2_NVIM = addr }, {
	{
		"tools/call",
		{ name = "task_update", arguments = { action = "content", id = note_id, content = "note renamed gamma" } },
	},
	{ "tools/call", { name = "task_remove", arguments = { action = "archive", id = note_id } } },
	{ "tools/call", { name = "task_remove", arguments = { action = "unarchive", id = note_id } } },
	{ "tools/call", { name = "task_remove", arguments = { action = "delete", id = note_id } } },
})
check("task_update/content", txt(res2[1]) and txt(res2[1]):find("note renamed gamma") ~= nil, txt(res2[1]))
check("task_remove/archive", txt(res2[2]) and txt(res2[2]):find("archived") ~= nil, txt(res2[2]))
check("task_remove/unarchive", txt(res2[3]) and txt(res2[3]):find("unarchived") ~= nil, txt(res2[3]))
check("task_remove/delete", txt(res2[4]) and txt(res2[4]):find("deleted") ~= nil, txt(res2[4]))

-- 只读模式
local ro = run({ TODO2_NVIM = addr, TODO2_MCP_READONLY = "1" }, {
	{ "tools/call", { name = "task_create", arguments = { action = "note", content = "blocked" } } },
	{ "tools/call", { name = "task_query", arguments = { action = "list" } } },
})
check("readonly blocks write", txt(ro[1]) and txt(ro[1]):lower():find("read%-only") ~= nil, txt(ro[1]))
check("readonly allows read", txt(ro[2]) and txt(ro[2]):find("bridge alpha task") ~= nil)

-- 多实例项目路由
local rt = run({ TODO2_PROJECT = "todo2-mcp-test-proj" }, {
	{ "tools/call", { name = "task_query", arguments = { action = "info" } } },
})
check("TODO2_PROJECT routing", txt(rt[1]) and txt(rt[1]):find("todo2%-mcp%-test%-proj") ~= nil, txt(rt[1]))

-- cwd 推导项目路由：不设 TODO2_NVIM / TODO2_PROJECT，靠 cwd basename 命中 projects.json
local cw = run({}, {
	{ "tools/call", { name = "task_query", arguments = { action = "info" } } },
}, { cwd = "/tmp/todo2-mcp-test-proj" })
check("cwd project routing", txt(cw[1]) and txt(cw[1]):find("todo2%-mcp%-test%-proj") ~= nil, txt(cw[1]))

-- TODO2_NVIM 指向死 socket 时，存活性校验应跳过它并回落到按项目的注册表
local dead = run({ TODO2_NVIM = "/tmp/todo2-dead.sock" }, {
	{ "tools/call", { name = "task_query", arguments = { action = "info" } } },
}, { cwd = "/tmp/todo2-mcp-test-proj" })
check("dead TODO2_NVIM falls back", txt(dead[1]) and txt(dead[1]):find("todo2%-mcp%-test%-proj") ~= nil, txt(dead[1]))

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
