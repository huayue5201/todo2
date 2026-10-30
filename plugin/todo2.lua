-- File: plugin/todo2.lua
-- 轻量入口：只注册标准命令与 TODO 文件检测，不提供任何默认键位。
-- 所有映射由用户自行配置（<cmd>TodoXxx<cr> 或直接调用模块函数）。
-- 真正的初始化（require("todo2").setup()）在首次需要时执行。

if vim.g.loaded_todo2 then
	return
end
vim.g.loaded_todo2 = 1

---------------------------------------------------------------------
-- 用户配置（在 init.lua 中设置 vim.g.todo2_config，供惰性 setup 使用）
---------------------------------------------------------------------
vim.g.todo2_config = vim.g.todo2_config or {}

---------------------------------------------------------------------
-- 惰性初始化：首次触发时执行一次 setup
---------------------------------------------------------------------
local function ensure_setup()
	local todo2 = require("todo2")
	if not todo2.is_setup() then
		todo2.setup(vim.g.todo2_config)
	end
end

---------------------------------------------------------------------
-- 标准命令（惰性）
---------------------------------------------------------------------
local function define(name, fn, opts)
	opts = opts or {}
	vim.api.nvim_create_user_command(name, function(cmd_args)
		ensure_setup()
		fn(cmd_args)
	end, opts)
end

-- 同步 / 视图
define("TodoSync", function(cmd_args)
	if cmd_args.bang then
		require("todo2.commands").reconcile()
		return
	end
	require("todo2.commands").sync_current()
end, {
	bang = true,
	desc = "Sync TODO files with the store (! = full reconcile; the file is the source of truth)",
})
define("TodoDoctor", function(cmd_args)
	require("todo2.commands").doctor(cmd_args.bang)
end, { bang = true, desc = "Check main/archive id conflicts; ! also sweeps orphan tasks" })

-- 文件操作

-- 任务状态
define("TodoToggle", function(cmd_args)
	local handlers = require("todo2.handlers")
	if cmd_args.range > 0 and cmd_args.line1 ~= cmd_args.line2 then
		return handlers.ui_toggle_selected(cmd_args.line1, cmd_args.line2)
	end
	return handlers.toggle_task_status()
end, { range = true, desc = "Toggle task status; with a line range toggles every selected task" })
define("TodoDel", function(cmd_args)
	require("todo2.handlers").smart_delete(cmd_args)
end, {
	desc = "Smart delete task(s); supports a line range; ! also deletes child tasks",
	range = true,
	bang = true,
})
define("TodoStatus", function(cmd_args)
	if cmd_args.bang then
		require("todo2.handlers").cycle_status()
		return
	end
	require("todo2.ui.status").show_status_menu()
end, { bang = true, desc = "Choose task status (! = cycle to the next one)" })
define("TodoLink", function(args)
	require("todo2.handlers.link").link_task(args.args ~= "" and args.args or nil)
end, { nargs = "?", desc = "Link current code line to an existing task" })

-- 任务创建 / 编辑
define("TodoAdd", function()
	require("todo2.creation.manager").start_session()
end, { desc = "Create task from code" })
define("TodoInsert", function(cmd_args)
	local handlers = require("todo2.handlers")
	local sub = (cmd_args.fargs[1] or ""):lower()
	if sub == "sub" or sub == "subtask" then
		return handlers.ui_insert_subtask()
	end
	if sub == "sibling" then
		return handlers.ui_insert_sibling()
	end
	if sub ~= "" and sub ~= "task" then
		vim.notify("[todo2] usage: :TodoInsert [task|sub|sibling]", vim.log.levels.ERROR)
		return
	end
	handlers.ui_insert_task()
end, {
	nargs = "?",
	desc = "New task (sub = subtask, sibling = sibling task)",
	complete = function()
		return { "task", "sub", "sibling" }
	end,
})

-- 归档
local function archive_module()
	return require("todo2.ui.archive")
end

define("TodoArchive", function(cmd_args)
	archive_module().archive_task_group({ force = cmd_args.bang })
end, { bang = true, desc = "Archive task group (! forces unfinished)" })
define("TodoUnarchive", function()
	archive_module().unarchive()
end, { desc = "Unarchive a task group" })
define("TodoArchiveView", function(cmd_args)
	local viewer = require("todo2.task.viewer")
	if cmd_args.bang then
		viewer.show_archive_qf()
		return
	end
	viewer.show_archive_view()
end, { bang = true, desc = "Show archived task tree in the quickfix (! = list archived anchors only)" })

-- 标签
define("TodoTag", function(cmd_args)
	require("todo2.handlers.tags").tag_cmd(cmd_args)
end, { nargs = "*", desc = "Add/remove/set tags on the task at cursor" })

define("TodoDue", function(cmd_args)
	require("todo2.handlers.due").due_cmd(cmd_args)
end, { nargs = "*", desc = "Set/clear the due date (@YYYY-MM-DD) on the task at cursor" })

define("TodoCalendar", function(cmd_args)
	require("todo2.commands").calendar(cmd_args)
end, { nargs = "?", desc = "Month calendar of tasks with a due date (optional YYYY-MM)" })

define("TodoFilter", function(cmd_args)
	require("todo2.handlers.filter").filter_cmd(cmd_args)
end, {
	nargs = "*",
	bang = true,
	desc = "Filter by tags/status/path; save NAME | @NAME | list | delete NAME",
})

define("TodoSort", function(cmd_args)
	require("todo2.ui.drawer").sort_cmd(cmd_args)
end, { nargs = "?", desc = "Sort drawer siblings: status | default" })

-- git 集成



-- 链接 / 跳转
define("TodoLinks", function(cmd_args)
	local handlers = require("todo2.handlers")
	if cmd_args.bang then
		handlers.show_buffer_links_loclist()
		return
	end
	handlers.show_project_links_qf()
end, { bang = true, desc = "Show all backlink markers (QF); ! = current buffer only (LocList)" })
define("TodoJump", function()
	if not require("todo2.task.jumper").jump_dynamic() then
		vim.notify("No linked task on the current line", vim.log.levels.WARN)
	end
end, { desc = "Dynamically jump TODO <-> code" })

define("TodoContext", function(args)
	require("todo2.handlers").show_context(args)
end, {
	nargs = "?",
	bang = true,
	complete = function()
		return { "markdown", "json" }
	end,
	desc = "Copy current task context (for AI)",
})

define("TodoMcp", function()
	require("todo2.mcp").command()
end, { desc = "Show MCP access info (for pi and other clients)" })

-- 打开 TODO 文件

-- 窗口 / 视图
define("TodoSet", function()
	require("todo2.ui.attributes").open_for_cursor()
end, { desc = "Edit status, tags and due date in one panel" })
define("TodoDrawer", function()
	require("todo2.ui.drawer").toggle()
end, { desc = "Toggle task tree drawer" })

---------------------------------------------------------------------
-- 分组入口：:TodoFile / :TodoView / :TodoTask / :TodoGit
--   高频动作保持平坦（:TodoToggle / :TodoDue / :TodoTag …），
--   低频维护类收进分组，成员仍是上面注册的原命令（别名保留）。
---------------------------------------------------------------------
---@type table<string, {desc: string, subs: table<string, fun(cmd_args: table)}>
local GROUPS = {
	file = {
		desc = "TODO file: new | rename | delete",
		subs = {
			new = function()
				require("todo2.handlers").create_todo_file()
			end,
			rename = function()
				require("todo2.handlers").rename_todo_file()
			end,
			delete = function()
				require("todo2.handlers").delete_todo_file()
			end,
		},
	},
	view = {
		desc = "Open the TODO view: float | split | vsplit | edit | close | preview",
		subs = {
			float = function()
				require("todo2.handlers").open_todo_float()
			end,
			split = function()
				require("todo2.handlers").open_todo_split_horizontal()
			end,
			vsplit = function()
				require("todo2.handlers").open_todo_split_vertical()
			end,
			edit = function()
				require("todo2.handlers").open_todo_edit()
			end,
			close = function()
				require("todo2.handlers").ui_close_window()
			end,
			preview = function()
				require("todo2.commands").smart_preview()
			end,
		},
	},
	task = {
		desc = "Task: rename | desc | promote",
		subs = {
			rename = function()
				require("todo2.handlers").edit_task_from_code()
			end,
			desc = function()
				require("todo2.handlers.description").edit()
			end,
			promote = function()
				require("todo2.handlers").promote_current()
			end,
		},
	},
	git = {
		desc = "Git: sync | review | blame",
		subs = {
			sync = function(cmd_args)
				require("todo2.handlers.git").sync({ force = cmd_args.bang })
			end,
			review = function()
				require("todo2.handlers.git").review()
			end,
			blame = function(cmd_args)
				require("todo2.handlers.git").blame(cmd_args.fargs[2])
			end,
		},
	},
}

--- 分组命令名：file → TodoFile
---@param key string
---@return string
local function group_command(key)
	return "Todo" .. key:sub(1, 1):upper() .. key:sub(2)
end

--- 分组成员名（排好序，用于提示与补全）
---@param key string
---@return string[]
local function group_members(key)
	local names = {}
	for name in pairs(GROUPS[key].subs) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

--- 执行分组子命令（直接调函数，不再转发旧命令）
---@param key string
---@param cmd_args table
local function run_group(key, cmd_args)
	local members = group_members(key)
	local name = group_command(key)
	local sub = (cmd_args.fargs[1] or ""):lower()

	if sub == "" then
		vim.notify(("[todo2] usage: :%s <%s>"):format(name, table.concat(members, "|")), vim.log.levels.INFO)
		return
	end

	local action = GROUPS[key].subs[sub]
	if not action then
		vim.notify(
			("[todo2] %s: no such subcommand: %s (available: %s)"):format(name, sub, table.concat(members, ", ")),
			vim.log.levels.ERROR
		)
		return
	end

	action(cmd_args)
end

for key, spec in pairs(GROUPS) do
	local group_key = key
	define(group_command(group_key), function(cmd_args)
		run_group(group_key, cmd_args)
	end, {
		nargs = "*",
		bang = true,
		range = true,
		desc = spec.desc,
		complete = function(arglead)
			local items = {}
			local lead = arglead:lower()
			for _, member in ipairs(group_members(group_key)) do
				if lead == "" or member:sub(1, #lead) == lead then
					items[#items + 1] = member
				end
			end
			return items
		end,
	})
end

---------------------------------------------------------------------
-- 统一入口：:Todo
--   :Todo                     任务抽屉（项目总览，再次执行关闭）
--   :Todo help                打开 :h todo2
--   :Todo <sub> [args]        等价于 :Todo<Sub> [args]（大小写不敏感，支持 ! 与行范围）
--   :Todo file new           分组入口，二级子命令同样可用
-- 子命令清单与描述直接从已注册命令派生，不另存一份，避免与命令定义漂移。
---------------------------------------------------------------------
local function todo_subcommands()
	local out = {}
	for name, def in pairs(vim.api.nvim_get_commands({})) do
		local sub = name:match("^Todo(.+)$")
		if sub then
			out[#out + 1] = { key = sub:lower(), name = name, desc = def.desc or "" }
		end
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

define("Todo", function(cmd_args)
	local first = cmd_args.fargs[1]
	if not first then
		require("todo2.ui.drawer").toggle()
		return
	end
	if first == "help" then
		vim.cmd("help todo2")
		return
	end
	local lookup = {}
	for _, item in ipairs(todo_subcommands()) do
		lookup[item.key] = item.name
	end
	local target = lookup[first:lower()]
	if not target then
		vim.notify("todo2: no such subcommand: " .. first .. " (try :Todo help)", vim.log.levels.ERROR)
		return
	end
	local rest = {}
	for i = 2, #cmd_args.fargs do
		rest[#rest + 1] = cmd_args.fargs[i]
	end
	local range = ""
	if cmd_args.range > 0 then
		range = string.format("%d,%d", cmd_args.line1, cmd_args.line2)
	end
	local tail = #rest > 0 and (" " .. table.concat(rest, " ")) or ""
	-- 目标命令不支持 ! 时丢掉 bang，避免 E477
	local def = vim.api.nvim_get_commands({})[target]
	local bang = (cmd_args.bang and def and def.bang == 1) and "!" or ""
	vim.cmd(range .. target .. bang .. tail)
end, {
	desc = "todo2 entry: drawer, or `:Todo <sub>` for any :Todo* command (`:Todo help`)",
	nargs = "*",
	bang = true,
	range = true,
	complete = function(arglead, cmdline)
		local lead = arglead:lower()
		local words = vim.split(cmdline, "%s+", { trimempty = false })
		local first = words[2] or ""
		local group = GROUPS[first:lower()]
		local items = {}

		-- 已经敲完分组名（:Todo file …）时，补全该分组的二级子命令
		if group and (words[3] ~= nil or cmdline:match("%s$")) then
			for _, member in ipairs(group_members(first:lower())) do
				if lead == "" or member:sub(1, #lead) == lead then
					items[#items + 1] = member
				end
			end
		end

		if #items == 0 then
			for _, item in ipairs(todo_subcommands()) do
				if lead == "" or item.key:sub(1, #lead) == lead then
					items[#items + 1] = item.key
				end
			end
			if lead == "" or ("help"):sub(1, #lead) == lead then
				items[#items + 1] = "help"
			end
		end

		table.sort(items)
		return items
	end,
})

---------------------------------------------------------------------
-- 核心键位（保留少数高频智能键，其余映射由用户通过命令自行配置）
---------------------------------------------------------------------
local function map_fallback(lhs, handler, opts)
	opts = opts or {}
	vim.keymap.set("n", lhs, function()
		ensure_setup()
		if not handler() then
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "n", false)
		end
	end, opts)
end

map_fallback("<CR>", function()
	return require("todo2.handlers").toggle_task_status()
end, { desc = "Toggle task status" })
map_fallback("<BS>", function()
	return require("todo2.handlers").smart_delete()
end, { desc = "Smart delete task" })
-- 可视模式 <BS>：批量删除选中范围内的任务（多行 = 取最外层 + 连同子树）。
-- 只在 TODO 文件里生效，其余情况保持原生行为（可视模式 <BS> 本来无默认行为）。
vim.keymap.set("v", "<BS>", function()
	ensure_setup()
	if not require("todo2.utils.buffer").get_current_info().is_todo_file then
		return
	end
	local ok = require("todo2.handlers").smart_delete()
	-- 删完退出可视模式，否则残留的选区会让下一次操作落到空行上
	if ok then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
	end
end, { desc = "Smart delete selected tasks" })
map_fallback("<S-tab>", function()
	return require("todo2.handlers").cycle_status()
end, { desc = "Cycle status" })
map_fallback("<S-CR>", function()
	return require("todo2.handlers").edit_task_from_code()
end, { desc = "Edit task content" })
-- 单键跳转：<leader>mtj 无原生功能，不需要回退；未命中时提示
vim.keymap.set("n", "<c-[>", function()
	ensure_setup()
	if not require("todo2.task.jumper").jump_dynamic() then
		vim.notify("No linked task on the current line", vim.log.levels.WARN)
	end
end, { desc = "Dynamically jump TODO <-> code" })

---------------------------------------------------------------------
-- 惰性初始化触发：打开任意 buffer 时确保 setup 已执行。
-- 此前仅对 TODO 文件触发，导致重启后代码文件渲染不生效
--（setup 内注册的 BufRead 事件在首次打开时来不及触发）。
---------------------------------------------------------------------
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
	pattern = "*",
	callback = function()
		local was_setup = require("todo2").is_setup()
		ensure_setup()
		if not was_setup then
			-- 首次 setup：当前 buffer 已错过 setup 内注册的 BufRead 事件，手动渲染一次
			local buf = vim.api.nvim_get_current_buf()
			vim.defer_fn(function()
				pcall(require("todo2.autocmds").render_buffer, buf)
			end, 50)
		end
	end,
})
