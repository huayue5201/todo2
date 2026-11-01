-- test/mcp_registry.lua —— projects.json 按绝对路径登记：同名目录互不覆盖。
-- 运行：./scripts/test.sh mcp_registry
--
-- 场景：/…/a/proj 与 /…/b/proj 两个项目同名（basename 都是 proj），各自跑一个
-- 活着的 nvim，共享同一个 XDG_CACHE_HOME（= 同一个 projects.json）。
-- 断言：
--   1) 注册表里出现两条【不同的绝对路径】键（旧实现只剩一条 "proj"，后者覆盖前者）
--   2) 从 a/proj 里启动的 bridge 只看到 a 的任务，从 b/proj 只看到 b 的任务
--   3) TODO2_PROJECT=<绝对路径> 可精确钉住
--   4) TODO2_PROJECT=<名字> 在只有一条同名时可用

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local nvim = vim.v.progpath
local bridge = root .. "/mcp/todo2-mcp.lua"
local server = root .. "/test/mcp_server.lua"

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local base = vim.fn.fnamemodify(vim.fn.tempname(), ":p"):gsub("(.)/+$", "%1")
local jobs = {}

---拉起一个 fixture 实例；返回 { dir = 项目目录, ready = 就绪文件, task = 任务正文 }
local function spawn(label, task)
	local dir = base .. "/" .. label .. "/proj"
	local ready = base .. "/" .. label .. ".ready"
	local home = base .. "/" .. label .. "-home"
	vim.fn.mkdir(dir, "p")
	vim.fn.mkdir(home, "p")
	vim.fn.delete(ready)

	local env = {
		HOME = home,
		TODO2_FIXTURE_DIR = dir,
		TODO2_FIXTURE_READY = ready,
		TODO2_FIXTURE_TASK = task,
		-- 共享缓存目录 = 共享 projects.json（这正是要测的东西）
		XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME or (home .. "/.cache"),
		XDG_DATA_HOME = vim.env.XDG_DATA_HOME or (home .. "/.local/share"),
		XDG_STATE_HOME = vim.env.XDG_STATE_HOME or (home .. "/.local/state"),
	}
	jobs[#jobs + 1] = vim.fn.jobstart({ nvim, "--headless", "-u", "NONE", "-l", server }, { env = env })

	local deadline = vim.loop.now() + 30000
	while vim.fn.filereadable(ready) == 0 and vim.loop.now() < deadline do
		vim.wait(50)
	end
	check(label .. ": fixture ready", vim.fn.filereadable(ready) == 1)
	local lines = vim.fn.filereadable(ready) == 1 and vim.fn.readfile(ready) or {}
	return { dir = dir, addr = lines[1], task = task }
end

---以给定 env / cwd 启动 bridge，发一次 task_query list，返回文本
local function query_list(env, cwd)
	local out = {}
	local job = vim.fn.jobstart({ nvim, "--headless", "-u", "NONE", "-l", bridge }, {
		env = (env and next(env)) and env or vim.empty_dict(),
		cwd = cwd,
		on_stdout = function(_, data)
			for _, l in ipairs(data or {}) do
				if l ~= "" then
					out[#out + 1] = l
				end
			end
		end,
	})
	vim.fn.chansend(
		job,
		vim.json.encode({
			jsonrpc = "2.0",
			id = 1,
			method = "tools/call",
			params = { name = "task_query", arguments = { action = "list" } },
		}) .. "\n"
	)
	local deadline = vim.loop.now() + 20000
	while #out == 0 and vim.loop.now() < deadline do
		vim.wait(50)
	end
	vim.fn.jobstop(job)
	local line = out[1]
	if not line then
		return nil
	end
	local ok, dec = pcall(vim.json.decode, line)
	if not ok or not dec then
		return nil
	end
	local content = dec.result and dec.result.content and dec.result.content[1]
	return content and content.text
end

local a = spawn("a", "task in project a")
local b = spawn("b", "task in project b")

check("a and b share a basename", vim.fn.fnamemodify(a.dir, ":t") == vim.fn.fnamemodify(b.dir, ":t"))

-- 1) 注册表：两条绝对路径键
do
	local reg_path = (vim.env.XDG_CACHE_HOME or (vim.fn.stdpath("cache"))) .. "/nvim/todo2/projects.json"
	local reg = {}
	if vim.fn.filereadable(reg_path) == 1 then
		local ok, dec = pcall(vim.json.decode, table.concat(vim.fn.readfile(reg_path), "\n"))
		if ok and type(dec) == "table" then
			reg = dec
		end
	end
	local key_a = vim.uv.fs_realpath(a.dir) or a.dir
	local key_b = vim.uv.fs_realpath(b.dir) or b.dir
	check("registry has an absolute key for project a", reg[key_a] ~= nil, vim.inspect(reg))
	check("registry has an absolute key for project b", reg[key_b] ~= nil, vim.inspect(reg))
	check("the two keys differ", key_a ~= key_b)
	check("registry is free of legacy basename keys", reg["proj"] == nil, vim.inspect(reg))
end

-- 2) 自动路由：各自只看到自己的任务
do
	local ta = query_list({}, a.dir) or ""
	local tb = query_list({}, b.dir) or ""
	check("project a sees its own task", ta:find("task in project a", 1, true) ~= nil, ta)
	check("project a does not see b's task", ta:find("task in project b", 1, true) == nil, ta)
	check("project b sees its own task", tb:find("task in project b", 1, true) ~= nil, tb)
	check("project b does not see a's task", tb:find("task in project a", 1, true) == nil, tb)
end

-- 3) 绝对路径钉住（从无关 cwd 启动也能命中）
do
	local t = query_list({ TODO2_PROJECT = a.dir }, base) or ""
	check("TODO2_PROJECT=<absolute path> pins project a", t:find("task in project a", 1, true) ~= nil, t)
end

-- 4) 名字钉住：两个同名项目 → 必须报歧义而不是猜
do
	local t = query_list({ TODO2_PROJECT = "proj" }, base) or ""
	check("TODO2_PROJECT=<name> rejects an ambiguous name", t:find("ambiguous", 1, true) ~= nil, t)
	check("ambiguity message lists both candidates", t:find(a.dir, 1, true) ~= nil and t:find(b.dir, 1, true) ~= nil, t)
end

for _, j in ipairs(jobs) do
	pcall(vim.fn.jobstop, j)
end

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd(fails == 0 and "qa!" or "cquit")
