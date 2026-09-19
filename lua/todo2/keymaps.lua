-- lua/todo2/keymaps.lua
-- 100% 覆盖旧系统所有映射的极简版本（修正 require 与归档/窗口调用）

local M = {}

local handlers = require("todo2.handlers")
local archive = require("todo2.archive")
local manager = require("todo2.creation.manager")
local jumper = require("todo2.task.jumper")

---------------------------------------------------------------------
-- 全局映射（旧系统 GLOBAL 全部覆盖）
---------------------------------------------------------------------
function M.setup_global()
	-- 文件操作
	vim.keymap.set("n", "<leader>mn", handlers.create_todo_file, { desc = "创建文件" })
	vim.keymap.set("n", "<leader>mr", handlers.rename_todo_file, { desc = "重命名文件" })
	vim.keymap.set("n", "<leader>md", handlers.delete_todo_file, { desc = "删除文件" })

	-- 归档 / 恢复（来自 todo2.archive）
	vim.keymap.set("n", "<leader>mg", archive.archive_task_group, { desc = "归档任务组" })
	vim.keymap.set("n", "<leader>mu", archive.restore_task, { desc = "恢复归档任务" })

	-- 状态操作
	vim.keymap.set("n", "<CR>", handlers.toggle_task_status, { desc = "切换任务状态" })
	vim.keymap.set("n", "<BS>", handlers.smart_delete, { desc = "智能删除任务" })
	vim.keymap.set("n", "<leader>mt", require("todo2.status").show_status_menu, { desc = "选择任务状态" })
	vim.keymap.set("n", "<c-[>", handlers.cycle_status, { desc = "循环切换状态" })

	-- 从代码创建任务
	vim.keymap.set("n", "<leader>ma", manager.start_session, { desc = "从代码创建任务" })

	-- 编辑任务
	vim.keymap.set("n", "<S-CR>", handlers.edit_task_from_code, {
		desc = "编辑任务内容",
	})

	-- 链接操作
	vim.keymap.set("n", "<leader>mQ", handlers.show_project_links_qf, { desc = "显示所有双链标记 (QF)" })
	vim.keymap.set(
		"n",
		"<leader>mL",
		handlers.show_buffer_links_loclist,
		{ desc = "显示当前缓冲区双链标记 (LocList)" }
	)

	-- 打开 TODO 文件（用 handlers 里已经封装好的 UI 调用）
	vim.keymap.set("n", "<leader>mf", handlers.open_todo_float, { desc = "浮窗打开" })
	vim.keymap.set("n", "<leader>ms", handlers.open_todo_split_horizontal, { desc = "水平分割打开" })
	vim.keymap.set("n", "<leader>mv", handlers.open_todo_split_vertical, { desc = "垂直分割打开" })
	vim.keymap.set("n", "<leader>me", handlers.open_todo_edit, { desc = "编辑模式打开" })

	-- 动态跳转 TODO <-> 代码
	vim.keymap.set("n", "<s-tab>", jumper.jump_dynamic, { desc = "动态跳转 TODO <-> 代码" })
end

---------------------------------------------------------------------
-- TODO 文件专用映射（旧系统 UI + TODO_EDIT 全覆盖）
---------------------------------------------------------------------
function M.setup_todo_filetype()
	vim.api.nvim_create_autocmd("BufEnter", {
		pattern = "*.todo.md",
		callback = function(args)
			local buf = args.buf

			-- 关闭窗口（现在用 ui_close_window，而不是 window 模块）
			vim.keymap.set("n", "q", handlers.ui_close_window, {
				buffer = buf,
				desc = "关闭窗口",
			})

			vim.keymap.set("n", "<C-r>", handlers.ui_refresh, {
				buffer = buf,
				desc = "刷新显示",
			})

			vim.keymap.set({ "v", "x" }, "<CR>", handlers.ui_toggle_selected, {
				buffer = buf,
				desc = "批量切换任务状态",
			})

			vim.keymap.set("n", "<leader>np", handlers.ui_insert_task, {
				buffer = buf,
				desc = "新建任务",
			})

			vim.keymap.set("n", "<leader>ns", handlers.ui_insert_subtask, {
				buffer = buf,
				desc = "新建子任务",
			})

			vim.keymap.set("n", "<leader>nn", handlers.ui_insert_sibling, {
				buffer = buf,
				desc = "新建平级任务",
			})
		end,
	})
end

---------------------------------------------------------------------
-- 初始化
---------------------------------------------------------------------
function M.setup()
	M.setup_global()
	M.setup_todo_filetype()
end

return M
