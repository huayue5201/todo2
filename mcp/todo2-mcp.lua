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

---@return string|nil
local function nvim_addr()
	local env = vim.env.TODO2_NVIM
	if env and env ~= "" then
		return env
	end
	local f = vim.fn.stdpath("cache") .. "/todo2/nvim.addr"
	if vim.fn.filereadable(f) == 1 then
		local lines = vim.fn.readfile(f)
		if lines[1] and lines[1] ~= "" then
			return lines[1]
		end
	end
	if vim.env.NVIM and vim.env.NVIM ~= "" then
		return vim.env.NVIM
	end
	return nil
end

local chan
local function ensure_chan()
	if chan then
		return chan
	end
	local addr = nvim_addr()
	if not addr then
		error("找不到 nvim 地址：请设置 TODO2_NVIM，或启动带 todo2 插件的 nvim", 0)
	end
	local ok, c = pcall(vim.fn.sockconnect, "pipe", addr, { rpc = true })
	if not ok or c == 0 then
		error("连接 nvim 失败: " .. addr, 0)
	end
	chan = c
	return chan
end

--- 在活着的 nvim 上执行 Lua（`...` 为 args），返回结果。
local function call_lua(code, args)
	return vim.rpcrequest(ensure_chan(), "nvim_exec_lua", code, args or {})
end

---------------------------------------------------------------------
-- 工具
---------------------------------------------------------------------

local TOOLS = {
	{
		name = "list_tasks",
		annotations = { readOnlyHint = true },
		description = "List tasks in the current Neovim project. Returns a JSON array of "
			.. "{id, content, status, tags, anchor?} where anchor = {source,state,path,line}. "
			.. "source is 'own' or 'inherited' (a supplement inheriting its parent's anchor); "
			.. "state is 'ok' | 'stale' | 'lost' | 'inherited'.",
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
			},
		},
	},
	{
		name = "get_task_tree",
		annotations = { readOnlyHint = true },
		description = "Return the project's task tree grouped by TODO file as JSON: "
			.. "{files:[{path, roots:[{id,content,status,tags,children?}]}]}.",
		inputSchema = { type = "object", properties = vim.empty_dict() },
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
		name = "migrate_tags",
		description = "One-time migration: convert legacy type statuses (fix / refactor / AI) into "
			.. "tags and reset the status to the default progress state, updating both the store and "
			.. "the TODO file lines. Returns the number of migrated tasks.",
		inputSchema = { type = "object", properties = vim.empty_dict() },
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
}

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
	if name == "list_tasks" then
		return call_lua("return vim.json.encode(require('todo2.ai').list(...))", { args })
	elseif name == "get_task_tree" then
		return call_lua("return vim.json.encode(require('todo2.ai').tree(...))", { args })
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
	elseif name == "migrate_tags" then
		return call_action("migrate_tags")
	elseif name == "link_code" then
		return call_anchors("link_code", { args.id, args.path, args.line })
	elseif name == "create_todo_file" then
		return call_action("create_todo_file", { args.name })
	elseif name == "complete_by_commit" then
		return call_action("complete_by_commit", { args })
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
		reply(msg.id, { content = { { type = "text", text = text } } })
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
