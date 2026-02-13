-- lua/todo2/keymaps/definitions.lua
local M = {}

local keymaps = require("todo2.keymaps")
local handlers = require("todo2.keymaps.handlers")
local archive_handlers = require("todo2.keymaps.archive")

---------------------------------------------------------------------
-- 注册所有处理器（仅保留有映射或真正需要的）
---------------------------------------------------------------------
function M.register_all_handlers()
	-- 全局处理器
	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"toggle_task_status",
		handlers.toggle_task_status,
		"智能切换任务状态"
	)

	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"archive_completed_tasks",
		archive_handlers.archive_completed_tasks,
		"归档当前文件已完成任务"
	)

	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"unarchive_task",
		archive_handlers.unarchive_task,
		"撤销归档当前任务"
	)

	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"cleanup_expired_archives",
		archive_handlers.cleanup_expired_archives,
		"清理过期归档任务"
	)

	keymaps.register_handler(keymaps.MODE.GLOBAL, "smart_delete", handlers.smart_delete, "智能删除任务/标记")
	keymaps.register_handler(keymaps.MODE.GLOBAL, "show_status_menu", handlers.show_status_menu, "选择任务状态")
	keymaps.register_handler(keymaps.MODE.GLOBAL, "cycle_status", handlers.cycle_status, "循环切换状态")
	keymaps.register_handler(keymaps.MODE.GLOBAL, "jump_dynamic", handlers.jump_dynamic, "动态跳转TODO↔代码")
	keymaps.register_handler(keymaps.MODE.GLOBAL, "preview_content", handlers.preview_content, "预览TODO或代码")
	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"start_unified_creation",
		handlers.start_unified_creation,
		"从代码创建任务（统一入口）"
	)
	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"create_child_from_code",
		handlers.create_child_from_code,
		"从代码中创建子任务"
	)
	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"show_project_links_qf",
		handlers.show_project_links_qf,
		"显示所有双链标记 (QuickFix)"
	)
	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"show_buffer_links_loclist",
		handlers.show_buffer_links_loclist,
		"显示当前缓冲区双链标记 (LocList)"
	)
	keymaps.register_handler(keymaps.MODE.GLOBAL, "open_todo_float", handlers.open_todo_float, "TODO:浮窗打开")
	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"open_todo_split_horizontal",
		handlers.open_todo_split_horizontal,
		"TODO:水平分割打开"
	)
	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"open_todo_split_vertical",
		handlers.open_todo_split_vertical,
		"TODO:垂直分割打开"
	)
	keymaps.register_handler(keymaps.MODE.GLOBAL, "open_todo_edit", handlers.open_todo_edit, "TODO:编辑模式打开")
	keymaps.register_handler(keymaps.MODE.GLOBAL, "create_todo_file", handlers.create_todo_file, "TODO:创建文件")
	keymaps.register_handler(keymaps.MODE.GLOBAL, "delete_todo_file", handlers.delete_todo_file, "TODO:删除文件")

	-- UI处理器（浮窗）
	keymaps.register_handler(keymaps.MODE.UI, "close", handlers.ui_close_window, "关闭窗口")
	keymaps.register_handler(keymaps.MODE.UI, "refresh", handlers.ui_refresh, "刷新显示")
	keymaps.register_handler(keymaps.MODE.UI, "insert_task", handlers.ui_insert_task, "新建任务")
	keymaps.register_handler(keymaps.MODE.UI, "insert_subtask", handlers.ui_insert_subtask, "新建子任务")
	keymaps.register_handler(keymaps.MODE.UI, "insert_sibling", handlers.ui_insert_sibling, "新建平级任务")
	keymaps.register_handler(
		keymaps.MODE.UI,
		"toggle_selected",
		handlers.ui_toggle_selected,
		"批量切换任务状态"
	)

	-- 代码文件处理器（仅保留实际使用的）
	keymaps.register_handler(
		keymaps.MODE.CODE,
		"edit_task_from_code",
		handlers.edit_task_from_code,
		"修改关联任务的内容（浮窗）"
	)

	-- ⚠️ 移除了所有无映射的处理器：
	--   create_link, toggle_insert, toggle_status, delete_task,
	--   toggle_marked_task, delete_mark
	--   以及整个 TODO_EDIT 模式（无映射）
end

---------------------------------------------------------------------
-- 定义所有映射
---------------------------------------------------------------------
function M.define_all_mappings()
	-- ==================== 全局映射 ====================
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tda",
		"archive_completed_tasks",
		{ mode = "n", desc = "归档当前文件已完成任务" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdu",
		"unarchive_task",
		{ mode = "n", desc = "撤销归档当前任务" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdx",
		"cleanup_expired_archives",
		{ mode = "n", desc = "清理过期归档任务" }
	)

	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<CR>",
		"toggle_task_status",
		{ mode = "n", desc = "智能切换任务状态" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<BS>",
		"smart_delete",
		{ mode = { "n", "v" }, desc = "智能删除任务/标记" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<Leader>ts",
		"show_status_menu",
		{ mode = "n", desc = "选择任务状态（正常/紧急/等待）" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<S-cr>",
		"cycle_status",
		{ mode = "n", desc = "循环切换状态（正常→紧急→等待）" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<tab>",
		"jump_dynamic",
		{ mode = "n", desc = "动态跳转 TODO <-> 代码" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>ta",
		"start_unified_creation",
		{ mode = "n", desc = "从代码创建任务（<CR>独立 / <C-CR>子任务）" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdq",
		"show_project_links_qf",
		{ mode = "n", desc = "显示所有双链标记 (QuickFix)" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdl",
		"show_buffer_links_loclist",
		{ mode = "n", desc = "显示当前缓冲区双链标记 (LocList)" }
	)
	keymaps.define_mapping(keymaps.MODE.GLOBAL, "K", "preview_content", { mode = "n", desc = "预览 TODO 或代码" })
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdf",
		"open_todo_float",
		{ mode = "n", desc = "TODO:浮窗打开" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tds",
		"open_todo_split_horizontal",
		{ mode = "n", desc = "TODO:水平分割打开" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdv",
		"open_todo_split_vertical",
		{ mode = "n", desc = "TODO:垂直分割打开" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tde",
		"open_todo_edit",
		{ mode = "n", desc = "TODO:编辑模式打开" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdn",
		"create_todo_file",
		{ mode = "n", desc = "TODO:创建文件" }
	)
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdd",
		"delete_todo_file",
		{ mode = "n", desc = "TODO:删除文件" }
	)

	-- ==================== UI窗口映射（浮动窗口）====================
	keymaps.define_mapping(keymaps.MODE.UI, "q", "close", { mode = "n", desc = "关闭窗口" })
	keymaps.define_mapping(keymaps.MODE.UI, "<C-r>", "refresh", { mode = "n", desc = "刷新显示" })
	keymaps.define_mapping(keymaps.MODE.UI, "<cr>", "toggle_task_status", { mode = "n", desc = "切换任务状态" })
	keymaps.define_mapping(
		keymaps.MODE.UI,
		"<cr>",
		"toggle_selected",
		{ mode = { "v", "x" }, desc = "批量切换任务状态" }
	)
	keymaps.define_mapping(keymaps.MODE.UI, "<leader>nt", "insert_task", { mode = "n", desc = "新建任务" })
	keymaps.define_mapping(keymaps.MODE.UI, "<leader>nT", "insert_subtask", { mode = "n", desc = "新建子任务" })
	keymaps.define_mapping(keymaps.MODE.UI, "<leader>ns", "insert_sibling", { mode = "n", desc = "新建平级任务" })

	-- ==================== 代码文件映射 ====================
	keymaps.define_mapping(keymaps.MODE.CODE, "e", "edit_task_from_code", { mode = "n", desc = "编辑任务内容" })

	-- ⚠️ 移除了所有无映射的 TODO_EDIT 模式映射（该模式已无注册）
end

---------------------------------------------------------------------
-- 初始化所有映射
---------------------------------------------------------------------
function M.setup()
	keymaps.clear_all()
	M.register_all_handlers()
	M.define_all_mappings()
	keymaps.setup_global_keymaps()
end

return M
