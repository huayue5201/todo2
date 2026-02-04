--- File: /Users/lijia/todo2/lua/todo2/keymaps/definitions.lua ---
-- lua/todo2/keymaps/definitions.lua
--- @module todo2.keymaps.definitions
--- @brief 按键映射定义配置

local M = {}

local keymaps = require("todo2.keymaps")
local handlers = require("todo2.keymaps.handlers")

---------------------------------------------------------------------
-- 注册所有处理器
---------------------------------------------------------------------
function M.register_all_handlers()
	-- 全局处理器
	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"toggle_task_status",
		handlers.toggle_task_status,
		"智能切换任务状态"
	)

	keymaps.register_handler(keymaps.MODE.GLOBAL, "smart_delete", handlers.smart_delete, "智能删除任务/标记")

	keymaps.register_handler(keymaps.MODE.GLOBAL, "show_status_menu", handlers.show_status_menu, "选择任务状态")

	keymaps.register_handler(keymaps.MODE.GLOBAL, "cycle_status", handlers.cycle_status, "循环切换状态")

	keymaps.register_handler(keymaps.MODE.GLOBAL, "create_link", handlers.create_link, "创建代码→TODO链接")

	keymaps.register_handler(keymaps.MODE.GLOBAL, "jump_dynamic", handlers.jump_dynamic, "动态跳转TODO↔代码")

	keymaps.register_handler(keymaps.MODE.GLOBAL, "preview_content", handlers.preview_content, "预览TODO或代码")

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

	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"cleanup_orphan_links_in_buffer",
		handlers.cleanup_orphan_links_in_buffer,
		"修复当前缓冲区孤立的标记"
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

	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"cleanup_expired_links",
		handlers.cleanup_expired_links,
		"清理过期存储数据"
	)

	keymaps.register_handler(
		keymaps.MODE.GLOBAL,
		"validate_all_links",
		handlers.validate_all_links,
		"验证所有链接"
	)

	-- UI处理器
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

	keymaps.register_handler(
		keymaps.MODE.UI,
		"toggle_insert",
		handlers.ui_toggle_insert,
		"切换任务状态（插入模式）"
	)

	keymaps.register_handler(keymaps.MODE.UI, "quick_save", handlers.quick_save, "保存TODO文件")

	-- TODO编辑模式处理器
	keymaps.register_handler(keymaps.MODE.TODO_EDIT, "toggle_status", handlers.toggle_task_status, "切换任务状态")

	keymaps.register_handler(keymaps.MODE.TODO_EDIT, "delete_task", handlers.smart_delete, "删除任务")

	keymaps.register_handler(keymaps.MODE.TODO_EDIT, "quick_save", handlers.quick_save, "保存TODO文件")

	-- 代码文件处理器
	keymaps.register_handler(
		keymaps.MODE.CODE,
		"toggle_marked_task",
		handlers.toggle_task_status,
		"切换标记的任务状态"
	)

	keymaps.register_handler(keymaps.MODE.CODE, "delete_mark", handlers.smart_delete, "删除标记")
end

---------------------------------------------------------------------
-- 定义所有映射
---------------------------------------------------------------------
function M.define_all_mappings()
	-- ==================== 全局映射 ====================

	-- 核心状态切换
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

	-- 状态管理
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

	-- 双链跳转
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"gj",
		"jump_dynamic",
		{ mode = "n", desc = "动态跳转 TODO <-> 代码" }
	)

	-- 创建链接
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tA",
		"create_link",
		{ mode = "n", desc = "创建代码→TODO 链接" }
	)

	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>ta",
		"create_child_from_code",
		{ mode = "n", desc = "从代码中创建子任务" }
	)

	-- 双链管理
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

	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdr",
		"cleanup_orphan_links_in_buffer",
		{ mode = "n", desc = "修复当前缓冲区孤立的标记" }
	)

	-- 预览
	keymaps.define_mapping(keymaps.MODE.GLOBAL, "K", "preview_content", { mode = "n", desc = "预览 TODO 或代码" })

	-- 文件管理
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

	-- 存储维护
	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdc",
		"cleanup_expired_links",
		{ mode = "n", desc = "清理过期存储数据" }
	)

	keymaps.define_mapping(
		keymaps.MODE.GLOBAL,
		"<leader>tdy",
		"validate_all_links",
		{ mode = "n", desc = "验证所有链接" }
	)

	-- ==================== UI窗口映射（浮动窗口）====================
	keymaps.define_mapping(keymaps.MODE.UI, "q", "close", { mode = "n", desc = "关闭窗口" })
	keymaps.define_mapping(keymaps.MODE.UI, "<C-r>", "refresh", { mode = "n", desc = "刷新显示" })

	keymaps.define_mapping(keymaps.MODE.UI, "<cr>", "toggle_task_status", { mode = "n", desc = "切换任务状态" })

	keymaps.define_mapping(keymaps.MODE.UI, "<c-cr>", "toggle_insert", { mode = "i", desc = "切换任务状态" })

	keymaps.define_mapping(
		keymaps.MODE.UI,
		"<cr>",
		"toggle_selected",
		{ mode = { "v", "x" }, desc = "批量切换任务状态" }
	)

	keymaps.define_mapping(keymaps.MODE.UI, "<leader>nt", "insert_task", { mode = "n", desc = "新建任务" })

	keymaps.define_mapping(keymaps.MODE.UI, "<leader>nT", "insert_subtask", { mode = "n", desc = "新建子任务" })

	keymaps.define_mapping(keymaps.MODE.UI, "<leader>ns", "insert_sibling", { mode = "n", desc = "新建平级任务" })

	keymaps.define_mapping(keymaps.MODE.UI, "<C-s>", "quick_save", { mode = "n", desc = "保存TODO文件" })

	-- ==================== TODO编辑模式映射（非浮动窗口）====================

	keymaps.define_mapping(keymaps.MODE.TODO_EDIT, "<C-s>", "quick_save", { mode = "n", desc = "保存TODO文件" })
end

---------------------------------------------------------------------
-- 初始化所有映射
---------------------------------------------------------------------
function M.setup()
	-- 清空现有映射
	keymaps.clear_all()

	-- 注册处理器
	M.register_all_handlers()

	-- 定义映射
	M.define_all_mappings()

	-- 设置全局映射
	keymaps.setup_global_keymaps()
end

return M
