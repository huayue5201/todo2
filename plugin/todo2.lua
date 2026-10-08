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
	vim.api.nvim_create_user_command(name, function(cmd_args)
		ensure_setup()
		fn(cmd_args)
	end, opts or {})
end

-- 同步 / 视图
define("TodoSync", function()
	require("todo2.commands").sync_current()
end)
define("SmartPreview", function()
	require("todo2.commands").smart_preview()
end, { desc = "Smart preview TODO/code" })

-- 文件操作
define("TodoNew", function()
	require("todo2.handlers").create_todo_file()
end, { desc = "Create TODO file" })
define("TodoRename", function()
	require("todo2.handlers").rename_todo_file()
end, { desc = "Rename TODO file" })
define("TodoDelete", function()
	require("todo2.handlers").delete_todo_file()
end, { desc = "Delete TODO file" })

-- 任务状态
define("TodoToggle", function()
	require("todo2.handlers").toggle_task_status()
end, { desc = "Toggle task status" })
define("TodoCycle", function()
	require("todo2.handlers").cycle_status()
end, { desc = "Cycle status" })
define("TodoDel", function()
	require("todo2.handlers").smart_delete()
end, { desc = "Smart delete task" })
define("TodoStatus", function()
	require("todo2.ui.status").show_status_menu()
end, { desc = "Choose task status" })
define("TodoDesc", function()
	require("todo2.handlers.description").edit()
end, { desc = "Edit task body" })
define("TodoLink", function(args)
	require("todo2.handlers.link").link_task(args.args ~= "" and args.args or nil)
end, { nargs = "?", desc = "Link current code line to an existing task" })

-- 任务创建 / 编辑
define("TodoAdd", function()
	require("todo2.creation.manager").start_session()
end, { desc = "Create task from code" })
define("TodoEditTask", function()
	require("todo2.handlers").edit_task_from_code()
end, { desc = "Edit task content" })
define("TodoInsert", function()
	require("todo2.handlers").ui_insert_task()
end, { desc = "New task" })
define("TodoInsertSub", function()
	require("todo2.handlers").ui_insert_subtask()
end, { desc = "New subtask" })
define("TodoInsertSibling", function()
	require("todo2.handlers").ui_insert_sibling()
end, { desc = "New sibling task" })

-- 归档
define("TodoArchive", function()
	require("todo2.ui.archive").archive_task_group()
end, { desc = "Archive task group" })

-- 标签
define("TodoTag", function(cmd_args)
	require("todo2.handlers.tags").tag_cmd(cmd_args)
end, { nargs = "*", desc = "Add/remove/set tags on the task at cursor" })

define("TodoFilter", function(cmd_args)
	require("todo2.handlers.tags").filter_cmd(cmd_args)
end, { nargs = "*", bang = true, desc = "Filter current TODO file by tags (no args or ! clears)" })

-- 迁移
define("TodoMigrateTags", function()
	local n = require("todo2.core.migrate").run()
	vim.notify(("[todo2] Migrated %d legacy type-status tasks to tags"):format(n), vim.log.levels.INFO)
end, { desc = "Migrate legacy type statuses (fix/refactor/AI) to tags" })

-- git 集成
define("TodoGitSync", function(cmd_args)
	require("todo2.handlers.git").sync({ force = cmd_args.bang })
end, { bang = true, desc = "Apply task references incrementally since the last synced commit (! ignores enable)" })

define("TodoGitReview", function()
	require("todo2.handlers.git").review()
end, { desc = "List tasks whose code anchors are in git-dirty files (QF)" })

define("TodoGitBlame", function(cmd_args)
	require("todo2.handlers.git").blame(cmd_args.fargs[1])
end, { nargs = "?", desc = "Show git history of a task's code anchor" })

-- 链接 / 跳转
define("TodoLinks", function()
	require("todo2.handlers").show_project_links_qf()
end, { desc = "Show all backlink markers (QF)" })
define("TodoLinksBuf", function()
	require("todo2.handlers").show_buffer_links_loclist()
end, { desc = "Show current buffer backlink markers (LocList)" })
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
define("TodoFloat", function()
	require("todo2.handlers").open_todo_float()
end, { desc = "Open TODO file in a float" })
define("TodoSplit", function()
	require("todo2.handlers").open_todo_split_horizontal()
end, { desc = "Open in horizontal split" })
define("TodoVSplit", function()
	require("todo2.handlers").open_todo_split_vertical()
end, { desc = "Open in vertical split" })
define("TodoEdit", function()
	require("todo2.handlers").open_todo_edit()
end, { desc = "Open in edit mode" })

-- 窗口 / 视图
define("TodoClose", function()
	require("todo2.handlers").ui_close_window()
end, { desc = "Close window" })
define("TodoToggleSel", function()
	require("todo2.handlers").ui_toggle_selected()
end, { desc = "Toggle selected tasks' status", range = true })
define("TodoDrawer", function()
	require("todo2.ui.drawer").toggle()
end, { desc = "Toggle task tree drawer" })

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
map_fallback("<S-tab>", function()
	return require("todo2.handlers").cycle_status()
end, { desc = "Cycle status" })
map_fallback("<S-CR>", function()
	return require("todo2.handlers").edit_task_from_code()
end, { desc = "Edit task content" })
-- 单键跳转：<C-,> 无原生功能，不需要回退；未命中时提示
vim.keymap.set("n", "<C-,>", function()
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
