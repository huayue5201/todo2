-- mcp/todo2-mcp.lua
-- todo2 的最小 MCP（stdio）服务。
--
-- 启动（由 MCP 客户端，例如 pi）：
--   nvim --headless -u NONE -l /path/to/todo2/mcp/todo2-mcp.lua
--
-- 两种模式：
--   * bridge（默认）：把工具调用转发到活着的 nvim 实例上的 todo2.ai。
--     nvim 地址解析顺序：$TODO2_NVIM → projects.json 里本项目的条目 → $NVIM。
--     注册表键是项目【绝对路径】（规范化、解析符号链接），因此同名目录互不覆盖；
--     $TODO2_PROJECT 可钉绝对路径，也可钉项目名（仅当该名字在注册表里唯一）。
--     旧版按 basename 写的键只用于显式 $TODO2_PROJECT=名字，不参与自动路由。
--     注册表由插件的 :TodoMcp / publish() 写入，setup 时自动 publish 需要
--     mcp = { publish = true }。
--     【不】回落到全局 <cache>/todo2/nvim.addr：那是「最后发布 socket 的 nvim」，
--     会静默把工具调用写进别的项目，因此找不到地址时直接报错而不是猜。
--   * standalone：本进程内直接启动 todo2 数据层，不再需要任何活着的 nvim。
--     通过 TODO2_MCP_STANDALONE=1 / TODO2_MCP_MODE=standalone / 命令行 --standalone 开启。
--     项目目录取 cwd，可用 TODO2_PROJECT_DIR 覆盖；可选 TODO2_NVIM_STORE3 / TODO2_RUNTIME
--     指定 nvim-store3 与额外 runtimepath。neovim 退化为纯 UI。
--
-- 两种模式共用同一套工具定义（TOOLS）与分发（DISPATCH）。

local PROTOCOL_DEFAULT = "2025-06-18"
local SUPPORTED = {
	["2025-11-25"] = true,
	["2025-06-18"] = true,
	["2025-03-26"] = true,
	["2024-11-05"] = true,
}

---------------------------------------------------------------------
-- JSON-RPC over stdio
---------------------------------------------------------------------

local function write(tbl)
	io.stdout:write(vim.json.encode(tbl), "\n")
	io.stdout:flush()
end

local function reply(id, result)
	write({ jsonrpc = "2.0", id = id, result = result })
end

local function reply_error(id, code, message)
	write({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

local function log(fmt, ...)
	io.stderr:write("todo2-mcp: " .. string.format(fmt, ...) .. "\n")
	io.stderr:flush()
end

---------------------------------------------------------------------
-- 运行模式 / standalone 数据层
---------------------------------------------------------------------

local function arg_has(flag)
	if type(arg) ~= "table" then
		return false
	end
	for _, v in ipairs(arg) do
		if v == flag then
			return true
		end
	end
	return false
end

--- 是否 standalone 模式（默认 bridge）。
local STANDALONE = (function()
	local mode = vim.env.TODO2_MCP_MODE
	if mode == "standalone" then
		return true
	elseif mode == "bridge" then
		return false
	end
	local s = vim.env.TODO2_MCP_STANDALONE
	if s == "1" or s == "true" or s == "yes" then
		return true
	end
	return arg_has("--standalone") or arg_has("standalone")
end)()

local unpack_fn = rawget(table, "unpack") or unpack
local load_chunk = loadstring or load

--- 在本进程内执行 dispatch 代码片段（`...` 为 args）。
local function exec_local(code, args)
	local chunk = assert(load_chunk(code))
	return chunk(unpack_fn(args or {}))
end

--- standalone 下写操作后强制落盘（store 默认 1s debounce，且本进程不泵事件循环）。
local function flush_store()
	if STANDALONE then
		pcall(function()
			require("todo2.store.nvim_store").flush()
		end)
		-- TODO 文件的重写走 autosave 的防抖定时器，本进程没有事件循环，
		-- 必须同步写一次，否则删除/归档只在 store 生效（md 会在下次导入时把任务复活）。
		pcall(function()
			require("todo2.core.autosave").flush_all()
		end)
	end
end

--- 在本进程内启动 todo2 数据层（无活动 nvim）。
local function boot_standalone()
	local src = debug.getinfo(1, "S").source:sub(2)
	local plugin_root = vim.fn.fnamemodify(src, ":p:h:h")

	local extra = vim.env.TODO2_RUNTIME
	if extra and extra ~= "" then
		for _, p in ipairs(vim.split(extra, ":", { plain = true })) do
			if p ~= "" then
				vim.opt.runtimepath:prepend(p)
			end
		end
	end
	local store3 = vim.env.TODO2_NVIM_STORE3
	if not store3 or store3 == "" then
		store3 = vim.fn.fnamemodify(plugin_root, ":h") .. "/nvim-store3"
	end
	if vim.fn.isdirectory(store3) == 1 then
		vim.opt.runtimepath:prepend(store3)
	end
	vim.opt.runtimepath:prepend(plugin_root)

	local projdir = vim.env.TODO2_PROJECT_DIR
	if projdir and projdir ~= "" then
		vim.fn.chdir(projdir)
	end

	-- 不要把自己 publish 成全局兜底 socket（否则会污染 nvim.addr / projects.json）
	vim.g.todo2_mcp_standalone = 1

	local ok, err = pcall(function()
		require("todo2").setup({})
	end)
	if not ok then
		log("standalone boot failed: %s", tostring(err))
	end

	-- setup 内的对账 / 孤儿回收走 vim.schedule，需泵一次事件循环
	vim.wait(300, function()
		return false
	end)
	pcall(function()
		require("todo2.core.reconcile").run()
	end)
	log("standalone: dir=%s", vim.fn.getcwd())
end

---------------------------------------------------------------------
-- nvim 连接
---------------------------------------------------------------------

---读取按项目注册表 projects.json（键=项目绝对路径，值=socket 地址）
---@param dir string
---@return table<string,string>
local function read_projects(dir)
	local reg = dir .. "/projects.json"
	if vim.fn.filereadable(reg) ~= 1 then
		return {}
	end
	local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(reg), "\n"))
	if ok and type(decoded) == "table" then
		return decoded
	end
	return {}
end

---把目录规范成注册表键：绝对路径 + 去尾斜杠 + 解析符号链接
---（与插件 lua/todo2/utils/project.lua 的 get_project_key 保持一致）
---@param path string|nil
---@return string|nil
local function project_key(path)
	if not path or path == "" then
		return nil
	end
	local p = vim.fn.fnamemodify(path, ":p")
	if p == "" then
		return nil
	end
	p = p:gsub("(.)/+$", "%1")
	local uv = vim.uv or vim.loop
	local real = uv and uv.fs_realpath and uv.fs_realpath(p)
	if real and real ~= "" then
		p = real
	end
	return p
end

---路径 basename
---@param path string
---@return string
local function basename(path)
	return (path:gsub("(.)/+$", "%1"):match("([^/]+)$") or path)
end

---旧版插件写的键：不是绝对路径，而是 cwd basename（同名项目互相覆盖，信息已丢失）
---@param key string
---@return boolean
local function is_legacy_key(key)
	return key:sub(1, 1) ~= "/"
end

---在注册表里定位本项目。
---解析顺序：cwd 绝对路径 → TODO2_PROJECT（绝对路径精确 / 项目名唯一匹配）→ 旧式名键（拒绝，见下）
---@param registry table<string,string>
---@param cwd string
---@return string|nil addr
---@return string|nil hint 定位失败时可直接展示的原因（nil = 注册表里根本没有本项目）
local function resolve_project(registry, cwd)
	local key = project_key(cwd)
	if key and registry[key] then
		return registry[key], nil
	end

	local pinned = vim.env.TODO2_PROJECT
	if pinned and pinned ~= "" then
		local pkey = project_key(pinned)
		if pkey and registry[pkey] then
			return registry[pkey], nil
		end
		if not is_legacy_key(pinned) then
			return nil, ("TODO2_PROJECT=%s (absolute path) has no registry entry"):format(pinned)
		end
		-- 名字 → 在注册表里按 basename 找；多义时报错而不是猜
		local hits = {}
		for k in pairs(registry) do
			if basename(k) == pinned then
				hits[#hits + 1] = k
			end
		end
		table.sort(hits)
		if #hits == 1 then
			return registry[hits[1]], nil
		end
		if #hits > 1 then
			return nil,
				("TODO2_PROJECT=%s is ambiguous (%d projects); pin the absolute path instead: %s"):format(
					pinned,
					#hits,
					table.concat(hits, ", ")
				)
		end
		return nil, ("TODO2_PROJECT=%s matches no registry entry"):format(pinned)
	end

	-- 旧式名键：只认「显式 TODO2_PROJECT」这一条路径。自动路由绝不能猜 ——
	-- 它正是「同名项目互相覆盖、任务写进别的项目」的根源。
	local legacy = {}
	for k, a in pairs(registry) do
		if is_legacy_key(k) then
			legacy[#legacy + 1] = ("%s -> %s"):format(k, a)
		end
	end
	if #legacy > 0 then
		table.sort(legacy)
		local shown = {}
		for i = 1, math.min(#legacy, 3) do
			shown[i] = legacy[i]
		end
		local more = #legacy > #shown and (", …(+" .. (#legacy - #shown) .. " more)") or ""
		return nil,
			("projects.json has no entry for this directory, only %d legacy name-keyed one(s) (e.g. %s%s). "
				.. "Those cannot tell same-named projects apart; run :TodoMcp in the editor you want to drive "
				.. "to re-register it by absolute path"):format(#legacy, table.concat(shown, ", "), more)
	end
	return nil, nil
end

---地址候选列表（按优先级去重）：
---1) TODO2_NVIM  2) projects.json 里本项目（绝对路径键）的条目  3) NVIM env
---
---注意：这里【不】回落到全局 `nvim.addr`。它是「最后发布 socket 的那个 nvim」，
---与当前目录毫无关系；一旦回落，工具调用会静默写进另一个项目（实测把 dotfiles
---仓库的任务建到了 data_pulse 项目里）。项目目录总能推导出来（cwd 绝对路径），
---所以宁可报错让用户启动/指定实例，也不够猜。
---@return string[] addrs
---@return string|nil hint 注册表定位失败的原因（用于报错）
local function nvim_addr_candidates()
	local dir = vim.fn.stdpath("cache") .. "/todo2"
	local out, seen = {}, {}
	local function add(a)
		if a and a ~= "" and not seen[a] then
			seen[a] = true
			table.insert(out, a)
		end
	end

	add(vim.env.TODO2_NVIM)

	local addr, hint = resolve_project(read_projects(dir), vim.fn.getcwd())
	if addr and addr ~= "" then
		add(addr)
	end

	-- 只有在「没有明确指定项目」时才回落到 $NVIM（启动我的那个实例）。
	-- 一旦用户指定了项目却定位失败（hint 有值），回落到 $NVIM 就是又一次「猜」：
	-- 它可能完全是另一个项目，正是跨项目写入的来源。
	if hint == nil then
		add(vim.env.NVIM)
	end

	return out, hint
end

---尝试连接地址，成功返回 channel，失败返回 nil（不抛错）
---@param addr string
---@return integer|nil
local function try_connect(addr)
	local ok, c = pcall(vim.fn.sockconnect, "pipe", addr, { rpc = true })
	if ok and c and c ~= 0 then
		return c
	end
	return nil
end

---本脚本自身的路径，即 MCP bridge 的路径；让报错里能直接给出可粘贴的启动命令。
---@return string|nil
local function bridge_path()
	local src = debug.getinfo(1, "S").source
	if src and src:sub(1, 1) == "@" then
		src = src:sub(2)
	end
	if src and src ~= "" then
		return src
	end
	return nil
end

---连不上时给出的可操作指引：说清查过哪里、以及三种各自的解法。
---仅用于 bridge 模式（standalone 模式下不会走到这里）。
---@param tried string[] 已经尝试连接但失败的地址
---@param hint string|nil 注册表定位失败的具体原因
---@return string
local function addr_help(tried, hint)
	local dir = vim.fn.stdpath("cache") .. "/todo2"
	local key = project_key(vim.fn.getcwd()) or vim.fn.getcwd()
	local lines = {
		"todo2 MCP (bridge mode) cannot reach a live Neovim for project '" .. vim.fn.getcwd() .. "'.",
		"searched: $TODO2_NVIM, " .. dir .. "/projects.json['" .. key .. "'], $NVIM",
	}
	if hint then
		lines[#lines + 1] = "registry: " .. hint
	end
	if tried and #tried > 0 then
		lines[#lines + 1] = "dead sockets tried: " .. table.concat(tried, ", ")
	end
	lines[#lines + 1] = "fix any ONE of:"
	lines[#lines + 1] = "  1) pin the socket explicitly (survives editor restarts, most reliable):"
	lines[#lines + 1] = "     pi mcp add todo2 --env TODO2_NVIM=<socket> -- nvim --headless -u NONE -l "
		.. (bridge_path() or "<plugin>/mcp/todo2-mcp.lua")
	lines[#lines + 1] = "  2) register the running editor: run :TodoMcp (publishes project -> socket)"
	lines[#lines + 1] = "     in the Neovim instance you want to drive. Note: automatic publish on setup"
	lines[#lines + 1] = "     is disabled unless todo2 config has mcp = { publish = true }; with it off you"
	lines[#lines + 1] = "     must publish manually via :TodoMcp (or run :TodoDoctor for a diagnosis)."
	lines[#lines + 1] = "  3) drop the bridge: pi mcp add todo2 --env TODO2_MCP_STANDALONE=1 -- nvim --headless -u NONE -l "
		.. (bridge_path() or "<plugin>/mcp/todo2-mcp.lua")
	lines[#lines + 1] = "     (standalone owns the data layer itself; no live editor needed)"
	return table.concat(lines, "\n")
end

local chan
local function ensure_chan()
	if chan then
		return chan
	end

	local addrs, hint = nvim_addr_candidates()
	if #addrs == 0 then
		error(addr_help({}, hint), 0)
	end

	-- 逐个候选做存活性校验；跳过已死的 socket（例如被其它项目覆盖或实例已退出）
	local tried = {}
	for _, addr in ipairs(addrs) do
		local c = try_connect(addr)
		if c then
			chan = c
			return chan
		end
		table.insert(tried, addr)
	end

	error(addr_help(tried, hint), 0)
end

-- 在活着的 nvim 上执行 Lua（`...` 为 args），返回结果。
-- channel 在 nvim 退出/重启后会失效，因此失败时丢弃缓存并重连重试一次。
local function call_lua(code, args)
	if STANDALONE then
		return exec_local(code, args)
	end

	local ok, res = pcall(vim.rpcrequest, ensure_chan(), "nvim_exec_lua", code, args or {})
	if ok then
		return res
	end

	chan = nil
	res = vim.rpcrequest(ensure_chan(), "nvim_exec_lua", code, args or {})
	return res
end

---------------------------------------------------------------------
-- 工具
---------------------------------------------------------------------

---------------------------------------------------------------------
-- 输出结构（structuredContent）
--
-- MCP 要求 structuredContent 必须是 JSON 对象（record），数组会被客户端拒绝，
-- 所以数组类工具（task_query list/search）统一包成 { items = [...] }，
-- 见 is_array_result()。
--
-- 这里刻意不声明 outputSchema：协议规定一个工具只能有一个 outputSchema，而
-- task_query 的 action 之间结果形状不同（list/search 是数组，其余是对象），
-- 声明任何一边都会让另一边校验失败。不声明时客户端只做结构化透传。
---------------------------------------------------------------------

---代码锚点 schema（create_task*tree 共用）。
local ANCHOR_SCHEMA = {
	type = "object",
	description = "REQUIRED code anchor. Point path/line at the exact 1-based line of the "
		.. "relevant symbol (function/struct/const/field). For long lines, pass col to anchor "
		.. "the exact token (0-based byte column, like nvim_win_get_cursor).",
	properties = {
		path = { type = "string", description = "Code file path" },
		line = { type = "integer", description = "Line number (1-based)" },
		col = {
			type = "integer",
			description = "Optional 0-based byte column of the target token on that line",
		},
	},
	required = { "path", "line" },
}

---数组结果（而非对象）的 (tool, action) → structuredContent 需包成 { items = [...] }。
---@param name string
---@param action string|nil
---@return boolean
local function is_array_result(name, action)
	return name == "task_query" and (action == "list" or action == "search")
end

local TOOLS = {
	{
		name = "task_query",
		annotations = { readOnlyHint = true },
		description = "Read todo2 state. action = 'list' (tasks in the current project), 'search' "
			.. "(full-text), 'tree' (task tree grouped by TODO file), 'info' (project overview), or "
			.. "'context' (full context for one task, markdown by default / JSON when format='json').",
		inputSchema = {
			type = "object",
			properties = {
				action = {
					type = "string",
					enum = { "list", "search", "tree", "info", "context" },
					description = "Which read to perform",
				},
				status = {
					type = "string",
					description = "Filter by status, e.g. todo / doing / blocked / completed / archived",
				},
				has_anchor = {
					type = "boolean",
					description = "Only tasks with (true) or without (false) a code anchor",
				},
				tag = {
					type = "string",
					description = "Only tasks carrying this tag (e.g. 'fix', 'backend')",
				},
				include_archived = {
					type = "boolean",
					description = "Also include archived (cold-store) tasks. Implied when status='archived'.",
				},
				limit = { type = "integer", description = "Max items to return (0/omitted = all)" },
				offset = { type = "integer", description = "Skip the first N items (pagination)" },
				query = { type = "string", description = "Substring to match (case-insensitive)" },
				id = { type = "string", description = "Task id" },
				format = {
					type = "string",
					enum = { "markdown", "json" },
					description = "Output format (default markdown)",
				},
				include_code = { type = "boolean", description = "Attach the code block source (default true)" },
			},
			required = { "action" },
		},
	},
	{
		name = "task_create",
		description = "Create todo2 tasks / TODO files. action = 'task' (anchored task), 'tree' "
			.. "(a whole task tree), 'note' (anchor-less checklist item), or 'file' (new TODO file).",
		inputSchema = {
			type = "object",
			properties = {
				action = {
					type = "string",
					enum = { "task", "tree", "note", "file" },
					description = "Which create to perform",
				},
				content = { type = "string", description = "Task content" },
				parent_id = { type = "string", description = "Optional parent task id (creates a subtask)" },
				path = {
					type = "string",
					description = "Optional TODO file path (default: the project's first TODO file)",
				},
				allow_duplicate = {
					type = "boolean",
					description = "Create even if a task with the same content already exists under the same parent (default false)",
				},
				tags = {
					type = "array",
					items = { type = "string" },
					description = "Optional tags (multi-value, orthogonal to status), e.g. ['fix','backend']",
				},
				due = {
					type = "string",
					description = "Optional due date: YYYY-MM-DD / today / tomorrow / +7d",
				},
				anchor = ANCHOR_SCHEMA,
				tasks = {
					type = "array",
					description = "Root nodes. Each node: {content, anchor:{path,line}, status?, tags?, children?:node[]}",
					items = {
						type = "object",
						properties = {
							content = { type = "string" },
							anchor = {
								type = "object",
								properties = {
									path = { type = "string", description = "Code file path" },
									line = { type = "integer", description = "1-based line of the symbol" },
								},
								required = { "path", "line" },
							},
							status = { type = "string", description = "Optional status label (todo/doing/blocked)" },
							tags = {
								type = "array",
								items = { type = "string" },
								description = "Optional tags for this node",
							},
							children = {
								type = "array",
								description = "Nested subtasks; each also requires {content, anchor:{path,line}}",
								items = {
									type = "object",
									properties = {
										content = { type = "string" },
										anchor = {
											type = "object",
											properties = {
												path = { type = "string", description = "Code file path" },
												line = { type = "integer", description = "1-based line of the symbol" },
											},
											required = { "path", "line" },
										},
										status = { type = "string", description = "Optional status label" },
										tags = { type = "array", items = { type = "string" } },
										children = { type = "array", items = { type = "object" } },
									},
									required = { "content", "anchor" },
								},
							},
						},
						required = { "content", "anchor" },
					},
				},
				name = { type = "string", description = "File name (extension optional)" },
			},
			required = { "action" },
		},
	},
	{
		name = "task_update",
		description = "Update a task. action = 'content' (rewrite its text), 'status', 'due' "
			.. "(set/clear due date), 'tags_set' (replace tags), 'tags_add' (union), or 'tags_remove'.",
		inputSchema = {
			type = "object",
			properties = {
				action = {
					type = "string",
					enum = { "content", "status", "due", "tags_set", "tags_add", "tags_remove" },
					description = "Which update to perform",
				},
				id = { type = "string", description = "Task id" },
				content = { type = "string", description = "New task text" },
				status = { type = "string", description = "New status" },
				tags = {
					type = "array",
					items = { type = "string" },
					description = "Full tag list to set (empty array clears tags), or the tags to add/remove",
				},
			},
			required = { "action" },
		},
	},
	{
		name = "task_link",
		description = "Bind tasks to code and verify anchors. action = 'link' (bind a task to a "
			.. "file/line), 'verify' (re-verify anchors), or 'complete_commit' (complete tasks named in a commit).",
		inputSchema = {
			type = "object",
			properties = {
				action = {
					type = "string",
					enum = { "link", "verify", "complete_commit" },
					description = "Which link operation to perform",
				},
				id = { type = "string", description = "Task id" },
				path = { type = "string", description = "Code file path" },
				line = { type = "integer", description = "Line number (1-based)" },
				col = {
					type = "integer",
					description = "Optional 0-based byte column of the target token on that line",
				},
				sha = { type = "string", description = "Commit hash (full or short)" },
				message = { type = "string", description = "Commit message to scan (used when sha is absent)" },
			},
			required = { "action" },
		},
	},
	{
		name = "task_remove",
		description = "Remove tasks. action = 'delete' (delete a task subtree), 'archive' (move a "
			.. "group to the cold store), or 'unarchive' (restore).",
		inputSchema = {
			type = "object",
			properties = {
				action = {
					type = "string",
					enum = { "delete", "archive", "unarchive" },
					description = "Which removal to perform",
				},
				id = { type = "string", description = "Task id" },
				force = { type = "boolean", description = "Archive even if the group has unfinished tasks" },
			},
			required = { "action" },
		},
	},
}

--- 写操作集合（tool/action），用于只读模式拦截；task_query/* 全部是读操作。
local WRITE_ACTIONS = {
	["task_create/task"] = true,
	["task_create/tree"] = true,
	["task_create/note"] = true,
	["task_create/file"] = true,
	["task_update/content"] = true,
	["task_update/status"] = true,
	["task_update/due"] = true,
	["task_update/tags_set"] = true,
	["task_update/tags_add"] = true,
	["task_update/tags_remove"] = true,
	["task_link/link"] = true,
	["task_link/verify"] = true,
	["task_link/complete_commit"] = true,
	["task_remove/delete"] = true,
	["task_remove/archive"] = true,
	["task_remove/unarchive"] = true,
}

--- 各 (tool/action) 的运行时必填参数。
local ACTION_REQUIRED = {
	["task_query/search"] = { "query" },
	["task_query/context"] = { "id" },
	["task_create/task"] = { "content", "anchor" },
	["task_create/tree"] = { "tasks" },
	["task_create/note"] = { "content" },
	["task_create/file"] = { "name" },
	["task_update/content"] = { "id", "content" },
	["task_update/status"] = { "id", "status" },
	["task_update/due"] = { "id" },
	["task_update/tags_set"] = { "id", "tags" },
	["task_update/tags_add"] = { "id", "tags" },
	["task_update/tags_remove"] = { "id", "tags" },
	["task_link/link"] = { "id", "path", "line" },
	["task_remove/delete"] = { "id" },
	["task_remove/archive"] = { "id" },
	["task_remove/unarchive"] = { "id" },
}

--- 是否处于只读模式（TODO2_MCP_READONLY=1）。
local function read_only()
	local v = vim.env.TODO2_MCP_READONLY
	return v == "1" or v == "true" or v == "yes"
end

--- 解析动作层返回的 JSON：{ ok = false, error } 视为工具错误。
---@return string|nil text, string|nil err
local function decode_action_result(text)
	if type(text) ~= "string" then
		return nil, "todo2 action returned no result"
	end
	local ok, decoded = pcall(vim.json.decode, text)
	if not ok or type(decoded) ~= "table" then
		-- 约定：动作层总是返回 JSON 对象；拿不到对象视为错误，不能当成功文本。
		return nil, "todo2 action returned an invalid result: " .. tostring(text)
	end
	if decoded.ok == false then
		return nil, decoded.error or "todo2 action failed"
	end
	return text, nil
end

--- 调用一个写操作，返回其 JSON 结果文本；失败时返回 err。
---@return string|nil text, string|nil err
local function call_action(fn, args)
	local code = (
		"local r, e = require('todo2.ai.actions').%s(...)\n"
		.. "if r == nil then return vim.json.encode({ ok = false, error = e }) end\n"
		.. "r.ok = true\n"
		.. "return vim.json.encode(r)"
	):format(fn)
	local text, err = decode_action_result(call_lua(code, args))
	if text then
		flush_store()
	end
	return text, err
end

--- 调用代码锚点硬约束层（todo2.ai.anchors）。
--- 该层强制 anchor 存在，并在写库后立即重新核验（stale → ok）。
---@return string|nil text, string|nil err
local function call_anchors(fn, args)
	local code = (
		"local r, e = require('todo2.ai.anchors').%s(...)\n"
		.. "if r == nil then return vim.json.encode({ ok = false, error = e }) end\n"
		.. "r.ok = true\n"
		.. "return vim.json.encode(r)"
	):format(fn)
	local text, err = decode_action_result(call_lua(code, args))
	if text then
		flush_store()
	end
	return text, err
end

--- (tool/action) → 调用表达式；沿用原有 RPC 分发逻辑，仅按 action 重新键化。
local DISPATCH = {
	["task_query/list"] = function(args)
		return call_lua("return vim.json.encode(require('todo2.ai').list(...))", { args })
	end,
	["task_query/tree"] = function(args)
		return call_lua("return vim.json.encode(require('todo2.ai').tree(...))", { args })
	end,
	["task_query/search"] = function(args)
		return call_lua("return vim.json.encode(require('todo2.ai').search(...))", { args })
	end,
	["task_query/info"] = function()
		return call_lua("return vim.json.encode(require('todo2.ai').project_info())")
	end,
	["task_query/context"] = function(args)
		if args.format == "json" then
			return call_lua(
				"local b = require('todo2.ai').build(...); return b and vim.json.encode(b) or nil",
				{ args.id, args }
			)
		end
		return call_lua(
			"local c = require('todo2.ai'); local b = c.build(...); return b and c.to_markdown(b) or nil",
			{ args.id, args }
		)
	end,
	["task_create/task"] = function(args)
		return call_anchors("create_task", { args })
	end,
	["task_create/tree"] = function(args)
		return call_anchors("create_task_tree", { args })
	end,
	["task_create/note"] = function(args)
		return call_action("create_task", { args })
	end,
	["task_create/file"] = function(args)
		return call_action("create_todo_file", { args.name })
	end,
	["task_update/content"] = function(args)
		return call_action("update_content", { args.id, args.content })
	end,
	["task_update/status"] = function(args)
		return call_action("set_status", { args.id, args.status })
	end,
	["task_update/due"] = function(args)
		return call_action("set_due", { args.id, args.due })
	end,
	["task_update/tags_set"] = function(args)
		return call_action("set_tags", { args.id, args.tags })
	end,
	["task_update/tags_add"] = function(args)
		return call_action("add_tag", { args.id, args.tags })
	end,
	["task_update/tags_remove"] = function(args)
		return call_action("remove_tag", { args.id, args.tags })
	end,
	["task_link/link"] = function(args)
		return call_anchors("link_code", { args.id, args.path, args.line, args.col })
	end,
	["task_link/verify"] = function(args)
		return call_anchors("verify", { args })
	end,
	["task_link/complete_commit"] = function(args)
		return call_action("complete_by_commit", { args })
	end,
	["task_remove/delete"] = function(args)
		return call_action("delete_task", { args.id })
	end,
	["task_remove/archive"] = function(args)
		return call_action("archive_task", { args.id, args })
	end,
	["task_remove/unarchive"] = function(args)
		return call_action("unarchive_task", { args.id })
	end,
}

---@return string|nil text, string|nil err
local function call_tool(name, args)
	args = args or {}
	local action = args.action
	if type(action) ~= "string" or action == "" then
		return nil, "missing required argument: action"
	end
	local key = name .. "/" .. action
	if read_only() and WRITE_ACTIONS[key] then
		return nil, "todo2 MCP is in read-only mode (TODO2_MCP_READONLY=1): '" .. key .. "' is disabled"
	end
	local handler = DISPATCH[key]
	if not handler then
		return nil, "unknown action: " .. key
	end
	local required = ACTION_REQUIRED[key]
	if required then
		for _, field in ipairs(required) do
			if args[field] == nil then
				return nil, key .. " needs: " .. table.concat(required, ", ")
			end
		end
	end
	if key == "task_link/complete_commit" and args.sha == nil and args.message == nil then
		return nil, key .. " needs: sha or message"
	end
	return handler(args)
end

---------------------------------------------------------------------
-- 协议处理
---------------------------------------------------------------------

local function handle_tools_call(msg)
	local params = msg.params or {}
	local ok, text, err = pcall(call_tool, params.name, params.arguments or {})
	if not ok then
		reply(msg.id, { content = { { type = "text", text = "todo2-mcp error: " .. tostring(text) } }, isError = true })
	elseif err then
		reply(msg.id, { content = { { type = "text", text = err } }, isError = true })
	elseif text == nil then
		reply(msg.id, { content = { { type = "text", text = "not found" } }, isError = true })
	else
		local result = { content = { { type = "text", text = text } } }
		-- 附上结构化结果（MCP 2025-06-18+）：客户端可免解析文本直接拿类型。
		-- MCP 要求 structuredContent 必须是 JSON 对象；数组类工具声明了
		-- outputSchema = { items = [...] }，这里必须包成对象，不能直接放数组。
		local dok, decoded = pcall(vim.json.decode, text)
		if dok and type(decoded) == "table" then
			if is_array_result(params.name, (params.arguments or {}).action) then
				result.structuredContent = { items = decoded }
			else
				result.structuredContent = decoded
			end
		end
		reply(msg.id, result)
	end
end

local function handle(msg)
	local method = msg.method
	if method == "initialize" then
		local requested = msg.params and msg.params.protocolVersion
		reply(msg.id, {
			protocolVersion = (requested and SUPPORTED[requested]) and requested or PROTOCOL_DEFAULT,
			capabilities = { tools = vim.empty_dict() },
			serverInfo = { name = "todo2", version = "0.1.0" },
			instructions = "Read and write todo2 tasks from the live Neovim instance: task lists, the "
				.. "task tree, and per-task context including the linked code block. Hard rule: every task "
				.. "created through this server must carry a code anchor {path,line} pointing at real code; "
				.. "anchors are re-verified on write, and verify_anchors can re-check them at any time.",
		})
	elseif method == "notifications/initialized" then
		-- JSON-RPC 通知：按协议不回包（故此处无事可做）
		local _ = method
	elseif method == "tools/list" then
		reply(msg.id, { tools = TOOLS })
	elseif method == "tools/call" then
		handle_tools_call(msg)
	elseif method == "ping" then
		reply(msg.id, {})
	elseif msg.id ~= nil then
		reply_error(msg.id, -32601, "Method not found: " .. tostring(method))
	end
end

---------------------------------------------------------------------
-- 主循环
---------------------------------------------------------------------

local function main()
	if STANDALONE then
		boot_standalone()
	end
	while true do
		local line = io.read("*line")
		if not line then
			break
		end
		if line ~= "" then
			local ok, msg = pcall(vim.json.decode, line)
			if ok and type(msg) == "table" then
				local hok, herr = pcall(handle, msg)
				if not hok then
					log("handle error: %s", tostring(herr))
				end
			else
				log("bad json: %s", tostring(line))
			end
		end
	end
end

main()
