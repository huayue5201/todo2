-- mcp/todo2-mcp.lua
-- todo2 的最小 MCP（stdio）服务：把工具调用转发到活着的 nvim 实例上的 todo2.ai。
--
-- 启动（由 MCP 客户端，例如 pi）：
--   nvim --headless -u NONE -l /path/to/todo2/mcp/todo2-mcp.lua
--
-- nvim 地址解析顺序：$TODO2_NVIM → $NVIM → <cache>/todo2/nvim.addr（由插件 publish）。
-- 本进程不需要加载 todo2 插件，只做 MCP ↔ nvim RPC 的转发。

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
-- nvim 连接
---------------------------------------------------------------------

---读取按项目注册表 projects.json（键=项目名，值=socket 地址）
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

---当前项目名：显式 TODO2_PROJECT 优先，否则用 cwd basename（与插件 get_project_name 一致）
---@return string|nil
local function project_name()
	local p = vim.env.TODO2_PROJECT
	if p and p ~= "" then
		return p
	end
	local cwd = vim.fn.getcwd()
	if cwd and cwd ~= "" then
		return vim.fn.fnamemodify(cwd, ":t")
	end
	return nil
end

---地址候选列表（按优先级去重）：
---1) TODO2_NVIM  2) 本项目的 projects.json 条目  3) 全局 nvim.addr 兜底  4) NVIM env
---@return string[]
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

	-- 多实例：按项目名定向到对应实例的 socket。若显式设置了 TODO2_PROJECT 却查不到，则严格报错，
	-- 避免静默连到别的项目；由 cwd 推导出项目名时允许回落到兜底地址。
	local project = project_name()
	if project then
		local addr = read_projects(dir)[project]
		if addr and addr ~= "" then
			add(addr)
		elseif vim.env.TODO2_PROJECT and vim.env.TODO2_PROJECT ~= "" then
			error(
				"no published nvim for project '" .. project .. "' (is the todo2 plugin loaded there?)",
				0
			)
		end
	end

	local f = dir .. "/nvim.addr"
	if vim.fn.filereadable(f) == 1 then
		local lines = vim.fn.readfile(f)
		add(lines[1])
	end

	add(vim.env.NVIM)

	return out
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

local chan
local function ensure_chan()
	if chan then
		return chan
	end

	local addrs = nvim_addr_candidates()
	if #addrs == 0 then
		error("cannot find nvim address: set TODO2_NVIM, or start nvim with the todo2 plugin", 0)
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

	error("failed to connect to any nvim; tried: " .. table.concat(tried, ", "), 0)
end

-- 在活着的 nvim 上执行 Lua（`...` 为 args），返回结果。
-- channel 在 nvim 退出/重启后会失效，因此失败时丢弃缓存并重连重试一次。
local function call_lua(code, args)
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
-- MCP 要求 structuredContent 必须是 JSON 对象（record），数组会被客户端拒绝。
-- 因此数组类工具统一包成 { items = [...] }，并在此声明 outputSchema 与之一致。
---------------------------------------------------------------------
local TASK_SUMMARY_SCHEMA = {
	type = "object",
	properties = {
		id = { type = "string" },
		content = { type = "string" },
		status = { type = "string" },
		tags = { type = "array", items = { type = "string" } },
		archived = { type = "boolean" },
		anchor = {
			type = "object",
			properties = {
				source = { type = "string", enum = { "own", "inherited" } },
				state = { type = "string", enum = { "ok", "stale", "lost", "inherited" } },
				path = { type = "string" },
				line = { type = "integer" },
			},
			required = { "source", "state", "path", "line" },
		},
	},
	required = { "id", "content", "status", "tags" },
}

---数组类工具的统一输出结构：{ items = [<task summary>] }
local TASK_LIST_OUTPUT_SCHEMA = {
	type = "object",
	properties = {
		items = { type = "array", items = TASK_SUMMARY_SCHEMA },
	},
	required = { "items" },
}

---返回 JSON 数组（而非对象）的工具名 → 调用结果需包成 { items = [...] }
local ARRAY_RESULT_TOOLS = {
	list_tasks = true,
	search_tasks = true,
}

local TOOLS = {
	{
		name = "list_tasks",
		annotations = { readOnlyHint = true },
		description = "List tasks in the current Neovim project. Returns a JSON array of "
			.. "{id, content, status, tags, anchor?} where anchor = {source,state,path,line}. "
			.. "source is 'own' or 'inherited' (a supplement inheriting its parent's anchor); "
			.. "state is 'ok' | 'stale' | 'lost' | 'inherited'.",
		outputSchema = TASK_LIST_OUTPUT_SCHEMA,
		inputSchema = {
			type = "object",
			properties = {
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
			},
		},
	},
	{
		name = "get_task_tree",
		annotations = { readOnlyHint = true },
		description = "Return the project's task tree grouped by TODO file as JSON: "
			.. "{files:[{path, roots:[{id,content,status,tags,anchor?,children?}]}]}. "
			.. "Pass include_archived to append a '(archived)' group built from the cold store.",
		inputSchema = {
			type = "object",
			properties = {
				include_archived = { type = "boolean", description = "Append the archived task tree" },
			},
		},
	},
	{
		name = "get_task_context",
		annotations = { readOnlyHint = true },
		description = "Assemble full context for one task: content, description, status, tags, the "
			.. "effective code anchor (path, line, block type/name/signature) with the code block "
			.. "source, and the task tree (ancestor chain + subtasks).",
		inputSchema = {
			type = "object",
			properties = {
				id = { type = "string", description = "Task id" },
				format = {
					type = "string",
					enum = { "markdown", "json" },
					description = "Output format (default markdown)",
				},
				include_code = { type = "boolean", description = "Attach the code block source (default true)" },
			},
			required = { "id" },
		},
	},
	{
		name = "create_task",
		description = "Create a task in a TODO file. Without parent_id it is appended to the project's "
			.. "active section; with parent_id it becomes a subtask. Idempotent by default: an existing "
			.. "task with the same content under the same parent is reused instead of duplicated. "
			.. "A code anchor is REQUIRED: every todo2 task must be linked to real code. The anchor's "
			.. "line is re-verified after creation, so its state comes back 'ok'.",
		inputSchema = {
			type = "object",
			properties = {
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
				anchor = {
					type = "object",
					description = "REQUIRED code anchor. Point path/line at the exact 1-based line of the "
						.. "relevant symbol (function/struct/const/field) in the codebase.",
					properties = {
						path = { type = "string", description = "Code file path" },
						line = { type = "integer", description = "Line number (1-based)" },
					},
					required = { "path", "line" },
				},
			},
			required = { "content", "anchor" },
		},
	},
	{
		name = "create_task_tree",
		description = "Create a whole task tree in one call. Every node (including group/root nodes) MUST "
			.. "carry an anchor = {path,line} pointing at real code. Nodes support an optional status and "
			.. "nested children. After creation, all touched files are re-verified so anchors report 'ok'. "
			.. "Use this to express a pipeline/stage breakdown instead of a flat markdown list.",
		inputSchema = {
			type = "object",
			properties = {
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
				parent_id = {
					type = "string",
					description = "Optional existing task id to nest the whole tree under",
				},
				path = { type = "string", description = "Optional TODO file path" },
				allow_duplicate = { type = "boolean" },
			},
			required = { "tasks" },
		},
	},
	{
		name = "verify_anchors",
		description = "Re-verify code anchors so stale/lost anchors are re-located against current code "
			.. "(stale → ok). Pass path to limit to one file, or omit it to verify every anchored file.",
		inputSchema = {
			type = "object",
			properties = {
				path = { type = "string", description = "Optional code file path to verify" },
			},
		},
	},
	{
		name = "set_status",
		description = "Set a task's status. Active labels come from the configured progress cycle "
			.. "(default: todo / doing / blocked); terminal values are 'completed' and 'archived'. "
			.. "Legacy type labels (fix / refactor / AI) are no longer statuses — use tags instead.",
		inputSchema = {
			type = "object",
			properties = {
				id = { type = "string", description = "Task id" },
				status = { type = "string", description = "New status" },
			},
			required = { "id", "status" },
		},
	},
	{
		name = "set_tags",
		description = "Replace a task's tags (tags are multi-value and orthogonal to status; e.g. "
			.. "a task can be 'todo' and tagged 'fix'+'backend'). Updates both the store and the TODO file line.",
		inputSchema = {
			type = "object",
			properties = {
				id = { type = "string", description = "Task id" },
				tags = {
					type = "array",
					items = { type = "string" },
					description = "Full tag list to set (empty array clears tags)",
				},
			},
			required = { "id", "tags" },
		},
	},
	{
		name = "add_tags",
		description = "Add tags to a task (union with existing tags).",
		inputSchema = {
			type = "object",
			properties = {
				id = { type = "string", description = "Task id" },
				tags = { type = "array", items = { type = "string" }, description = "Tags to add" },
			},
			required = { "id", "tags" },
		},
	},
	{
		name = "remove_tags",
		description = "Remove tags from a task.",
		inputSchema = {
			type = "object",
			properties = {
				id = { type = "string", description = "Task id" },
				tags = { type = "array", items = { type = "string" }, description = "Tags to remove" },
			},
			required = { "id", "tags" },
		},
	},
	{
		name = "link_code",
		description = "Bind a task to a code location (file path + line). The enclosing code block is "
			.. "recorded as context and the anchor is re-verified immediately (state → ok).",
		inputSchema = {
			type = "object",
			properties = {
				id = { type = "string", description = "Task id" },
				path = { type = "string", description = "Code file path" },
				line = { type = "integer", description = "Line number (1-based)" },
			},
			required = { "id", "path", "line" },
		},
	},
	{
		name = "create_todo_file",
		description = "Create a TODO file in the current project's TODO directory. If a file with "
			.. "that name already exists, its path is returned. The extension is optional "
			.. "(.todo.md is appended if missing).",
		inputSchema = {
			type = "object",
			properties = {
				name = { type = "string", description = "File name (extension optional)" },
			},
			required = { "name" },
		},
	},
	{
		name = "complete_by_commit",
		description = "Apply task references found in a commit (or commit message) and mark matching "
			.. "tasks completed. Provide either sha (full or short) or message. Unlike the sync "
			.. "command, it does not require git integration to be enabled.",
		inputSchema = {
			type = "object",
			properties = {
				sha = { type = "string", description = "Commit hash (full or short)" },
				message = { type = "string", description = "Commit message to scan (used when sha is absent)" },
			},
		},
	},
	{
		name = "search_tasks",
		annotations = { readOnlyHint = true },
		description = "Full-text search over task content / id / tags / description. Returns the same "
			.. "summary shape as list_tasks. Archived tasks are searched too unless include_archived=false.",
		outputSchema = TASK_LIST_OUTPUT_SCHEMA,
		inputSchema = {
			type = "object",
			properties = {
				query = { type = "string", description = "Substring to match (case-insensitive)" },
				status = { type = "string", description = "Optional status filter" },
				tag = { type = "string", description = "Optional tag filter" },
				include_archived = { type = "boolean", description = "Search archived tasks too (default true)" },
				limit = { type = "integer", description = "Max results (0/omitted = all)" },
				offset = { type = "integer", description = "Skip the first N results" },
			},
			required = { "query" },
		},
	},
	{
		name = "get_project_info",
		annotations = { readOnlyHint = true },
		description = "Return the current project overview: name, dir, cwd, TODO files (with task counts), "
			.. "and active/archived task totals.",
		inputSchema = { type = "object", properties = vim.empty_dict() },
	},
	{
		name = "create_note",
		description = "Create an anchor-less task (a plain checklist item) in a TODO file. Use this for "
			.. "notes/ideas that have no code location; use create_task when the task IS about code. "
			.. "Idempotent by default (same content + parent is reused).",
		inputSchema = {
			type = "object",
			properties = {
				content = { type = "string", description = "Task content" },
				parent_id = { type = "string", description = "Optional parent task id" },
				path = { type = "string", description = "Optional TODO file path" },
				allow_duplicate = { type = "boolean", description = "Bypass content de-duplication" },
				tags = { type = "array", items = { type = "string" }, description = "Optional tags" },
			},
			required = { "content" },
		},
	},
	{
		name = "update_content",
		description = "Change a task's text and rewrite its TODO line. Use this to fix a wrong task wording.",
		inputSchema = {
			type = "object",
			properties = {
				id = { type = "string", description = "Task id" },
				content = { type = "string", description = "New task text" },
			},
			required = { "id", "content" },
		},
	},
	{
		name = "delete_task",
		description = "Delete a task (and its subtree, relations, indexes and TODO line). Archived "
			.. "tasks must be unarchived first.",
		inputSchema = {
			type = "object",
			properties = {
				id = { type = "string", description = "Task id" },
			},
			required = { "id" },
		},
	},
	{
		name = "archive_task",
		description = "Archive a task group: move the subtree into the cold archive store and remove "
			.. "its lines from the TODO file. Reversible via unarchive_task.",
		inputSchema = {
			type = "object",
			properties = {
				id = { type = "string", description = "Root task id" },
				force = { type = "boolean", description = "Archive even if the group has unfinished tasks" },
			},
			required = { "id" },
		},
	},
	{
		name = "unarchive_task",
		description = "Restore an archived task group back to the main store and append it to its TODO file.",
		inputSchema = {
			type = "object",
			properties = {
				id = { type = "string", description = "Archived task id" },
			},
			required = { "id" },
		},
	},
}

--- 写操作工具集（用于只读模式拦截）。
local WRITE_TOOLS = {
	create_task = true,
	create_task_tree = true,
	create_note = true,
	set_status = true,
	set_tags = true,
	add_tags = true,
	remove_tags = true,
	link_code = true,
	create_todo_file = true,
	complete_by_commit = true,
	update_content = true,
	delete_task = true,
	archive_task = true,
	unarchive_task = true,
	verify_anchors = true,
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
	return decode_action_result(call_lua(code, args))
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
	return decode_action_result(call_lua(code, args))
end

---@return string|nil text, string|nil err
local function call_tool(name, args)
	args = args or {}
	if read_only() and WRITE_TOOLS[name] then
		return nil, "todo2 MCP is in read-only mode (TODO2_MCP_READONLY=1): '" .. tostring(name) .. "' is disabled"
	end
	if name == "list_tasks" then
		return call_lua("return vim.json.encode(require('todo2.ai').list(...))", { args })
	elseif name == "get_task_tree" then
		return call_lua("return vim.json.encode(require('todo2.ai').tree(...))", { args })
	elseif name == "search_tasks" then
		return call_lua("return vim.json.encode(require('todo2.ai').search(...))", { args })
	elseif name == "get_project_info" then
		return call_lua("return vim.json.encode(require('todo2.ai').project_info())")
	elseif name == "create_task" then
		return call_anchors("create_task", { args })
	elseif name == "create_task_tree" then
		return call_anchors("create_task_tree", { args })
	elseif name == "verify_anchors" then
		return call_anchors("verify", { args })
	elseif name == "set_status" then
		return call_action("set_status", { args.id, args.status })
	elseif name == "set_tags" then
		return call_action("set_tags", { args.id, args.tags })
	elseif name == "add_tags" then
		return call_action("add_tag", { args.id, args.tags })
	elseif name == "remove_tags" then
		return call_action("remove_tag", { args.id, args.tags })
	elseif name == "link_code" then
		return call_anchors("link_code", { args.id, args.path, args.line })
	elseif name == "create_todo_file" then
		return call_action("create_todo_file", { args.name })
	elseif name == "complete_by_commit" then
		return call_action("complete_by_commit", { args })
	elseif name == "create_note" then
		return call_action("create_task", { args })
	elseif name == "update_content" then
		return call_action("update_content", { args.id, args.content })
	elseif name == "delete_task" then
		return call_action("delete_task", { args.id })
	elseif name == "archive_task" then
		return call_action("archive_task", { args.id, args })
	elseif name == "unarchive_task" then
		return call_action("unarchive_task", { args.id })
	elseif name == "get_task_context" then
		if not args.id then
			return nil, "missing required argument: id"
		end
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
	end
	return nil, "unknown tool: " .. tostring(name)
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
			if ARRAY_RESULT_TOOLS[params.name] then
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
		-- 通知，无需响应
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
