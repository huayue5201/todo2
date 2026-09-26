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
	vim.api.nvim_create_user_command(name, function()
		ensure_setup()
		fn()
	end, opts or {})
end

-- 同步 / 视图
define("TodoSync", function() require("todo2.commands").sync_current() end)
define("Todo2Heatmap", function() require("todo2.commands").open_heatmap() end, { desc = "打开任务状态热图" })
define("SmartPreview", function() require("todo2.commands").smart_preview() end, { desc = "智能预览 TODO/代码" })

-- 文件操作
define("TodoNew", function() require("todo2.handlers").create_todo_file() end, { desc = "创建 TODO 文件" })
define("TodoRename", function() require("todo2.handlers").rename_todo_file() end, { desc = "重命名 TODO 文件" })
define("TodoDelete", function() require("todo2.handlers").delete_todo_file() end, { desc = "删除 TODO 文件" })

-- 任务状态
define("TodoToggle", function() require("todo2.handlers").toggle_task_status() end, { desc = "切换任务状态" })
define("TodoCycle", function() require("todo2.handlers").cycle_status() end, { desc = "循环切换状态" })
define("TodoDel", function() require("todo2.handlers").smart_delete() end, { desc = "智能删除任务" })
define("TodoStatus", function() require("todo2.ui.status").show_status_menu() end, { desc = "选择任务状态" })

-- 任务创建 / 编辑
define("TodoAdd", function() require("todo2.creation.manager").start_session() end, { desc = "从代码创建任务" })
define("TodoEditTask", function() require("todo2.handlers").edit_task_from_code() end, { desc = "编辑任务内容" })
define("TodoInsert", function() require("todo2.handlers").ui_insert_task() end, { desc = "新建任务" })
define("TodoInsertSub", function() require("todo2.handlers").ui_insert_subtask() end, { desc = "新建子任务" })
define("TodoInsertSibling", function() require("todo2.handlers").ui_insert_sibling() end, { desc = "新建平级任务" })

-- 归档
define("TodoArchive", function() require("todo2.ui.archive").archive_task_group() end, { desc = "归档任务组" })
define("TodoRestore", function() require("todo2.ui.archive").restore_task() end, { desc = "恢复归档任务" })

-- 链接 / 跳转
define("TodoLinks", function() require("todo2.handlers").show_project_links_qf() end, { desc = "显示所有双链标记 (QF)" })
define("TodoLinksBuf", function() require("todo2.handlers").show_buffer_links_loclist() end, { desc = "显示当前缓冲区双链标记 (LocList)" })
define("TodoJump", function() require("todo2.task.jumper").jump_dynamic() end, { desc = "动态跳转 TODO <-> 代码" })

-- 打开 TODO 文件
define("TodoFloat", function() require("todo2.handlers").open_todo_float() end, { desc = "浮窗打开 TODO 文件" })
define("TodoSplit", function() require("todo2.handlers").open_todo_split_horizontal() end, { desc = "水平分割打开" })
define("TodoVSplit", function() require("todo2.handlers").open_todo_split_vertical() end, { desc = "垂直分割打开" })
define("TodoEdit", function() require("todo2.handlers").open_todo_edit() end, { desc = "编辑模式打开" })

-- 窗口 / 视图
define("TodoClose", function() require("todo2.handlers").ui_close_window() end, { desc = "关闭窗口" })
define("TodoToggleSel", function() require("todo2.handlers").ui_toggle_selected() end, { desc = "批量切换选中任务状态", range = true })

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

map_fallback("<CR>", function() return require("todo2.handlers").toggle_task_status() end, { desc = "切换任务状态" })
map_fallback("<BS>", function() return require("todo2.handlers").smart_delete() end, { desc = "智能删除任务" })
map_fallback("<c-[>", function() return require("todo2.handlers").cycle_status() end, { desc = "循环切换状态" })
map_fallback("<S-CR>", function() return require("todo2.handlers").edit_task_from_code() end, { desc = "编辑任务内容" })
map_fallback("<s-tab>", function() return require("todo2.task.jumper").jump_dynamic() end, { desc = "动态跳转 TODO <-> 代码" })

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
