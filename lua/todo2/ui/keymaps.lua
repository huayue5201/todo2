-- lua/todo2/ui/keymaps.lua
--- @module todo2.ui.keymaps

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 通知函数（UI模块内部使用）
---------------------------------------------------------------------
local function show_notification(msg, level)
	level = level or vim.log.levels.INFO
	vim.notify(msg, level)
end

---------------------------------------------------------------------
-- UI 按键声明
---------------------------------------------------------------------
M.ui_keymaps = {
	close = { "n", "q", "关闭窗口" },
	refresh = { "n", "<C-r>", "刷新显示" },
	toggle = { "n", "<cr>", "切换任务状态" },
	toggle_insert = { "i", "<C-CR>", "切换任务状态" },
	toggle_selected = { { "v", "x" }, "<cr>", "批量切换任务状态" },
	new_task = { "n", "<leader>nt", "新建任务" },
	new_subtask = { "n", "<leader>nT", "新建子任务" },
	new_sibling = { "n", "<leader>ns", "新建平级任务" },
}

---------------------------------------------------------------------
-- UI 相关全局按键声明
---------------------------------------------------------------------
M.global_keymaps = {
	-----------------------------------------------------------------
	-- TODO 文件管理（UI相关部分）
	-----------------------------------------------------------------
	{
		"n",
		"<leader>tdf",
		function()
			local ui = module.get("ui")
			ui.select_todo_file("current", function(choice)
				if choice then
					ui.open_todo_file(choice.path, "float", 1, { enter_insert = false })
				end
			end)
		end,
		"TODO: 浮窗打开",
	},

	{
		"n",
		"<leader>tds",
		function()
			local ui = module.get("ui")
			ui.select_todo_file("current", function(choice)
				if choice then
					ui.open_todo_file(choice.path, "split", 1, {
						enter_insert = false,
						split_direction = "horizontal",
					})
				end
			end)
		end,
		"TODO: 水平分割打开",
	},

	{
		"n",
		"<leader>tdv",
		function()
			local ui = module.get("ui")
			ui.select_todo_file("current", function(choice)
				if choice then
					ui.open_todo_file(choice.path, "split", 1, {
						enter_insert = false,
						split_direction = "vertical",
					})
				end
			end)
		end,
		"TODO: 垂直分割打开",
	},

	{
		"n",
		"<leader>tde",
		function()
			local ui = module.get("ui")
			ui.select_todo_file("current", function(choice)
				if choice then
					ui.open_todo_file(choice.path, "edit", 1, { enter_insert = false })
				end
			end)
		end,
		"TODO: 编辑模式打开",
	},

	{
		"n",
		"<leader>tdn",
		function()
			module.get("ui").create_todo_file()
		end,
		"TODO: 创建文件",
	},

	{
		"n",
		"<leader>tdd",
		function()
			local ui = module.get("ui")
			ui.select_todo_file("current", function(choice)
				if choice then
					ui.delete_todo_file(choice.path)
				end
			end)
		end,
		"TODO: 删除文件",
	},
}

---------------------------------------------------------------------
-- 注册 UI 相关全局按键
---------------------------------------------------------------------
function M.setup_global_keymaps()
	for _, map in ipairs(M.global_keymaps) do
		local mode, lhs, fn, desc = map[1], map[2], map[3], map[4]
		vim.keymap.set(mode, lhs, fn, { desc = desc })
	end
end

---------------------------------------------------------------------
-- 键位设置函数（只负责绑定 handler，不再声明按键）
---------------------------------------------------------------------
function M.setup_keymaps(bufnr, win, ui_module)
	-- 安全刷新
	local function safe_refresh()
		if ui_module and ui_module.refresh then
			ui_module.refresh(bufnr)
		end
	end

	-----------------------------------------------------------------
	-- handler 映射表（逻辑不变）
	-----------------------------------------------------------------
	local handlers = {
		close = function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end,

		refresh = function()
			local conceal = module.get("ui.conceal")
			conceal.apply_conceal(bufnr)
			safe_refresh()
			vim.cmd("redraw")
		end,

		toggle = function()
			local core = module.get("core")
			local lnum = vim.fn.line(".")
			core.toggle_line(bufnr, lnum)
			safe_refresh()
		end,

		toggle_insert = function()
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)
			local core = module.get("core")
			local lnum = vim.fn.line(".")
			core.toggle_line(bufnr, lnum)
			safe_refresh()
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
		end,

		toggle_selected = function()
			local operations = module.get("ui.operations")
			local changed = operations.toggle_selected_tasks(bufnr, win)
			safe_refresh()
			return changed
		end,

		new_task = function()
			local operations = module.get("ui.operations")
			operations.insert_task("新任务", 0, bufnr, ui_module)
		end,

		new_subtask = function()
			local operations = module.get("ui.operations")
			operations.insert_task("新任务", 2, bufnr, ui_module)
		end,

		new_sibling = function()
			local operations = module.get("ui.operations")
			operations.insert_task("新任务", 0, bufnr, ui_module)
		end,
	}

	-----------------------------------------------------------------
	-- 绑定 UI 按键
	-----------------------------------------------------------------
	for key, def in pairs(M.ui_keymaps) do
		local modes = type(def[1]) == "table" and def[1] or { def[1] }
		local lhs = def[2]
		local desc = def[3]
		local handler = handlers[key]

		if handler then
			for _, mode in ipairs(modes) do
				vim.keymap.set(mode, lhs, handler, { buffer = bufnr, desc = desc })
			end
		end
	end

	-----------------------------------------------------------------
	-- 额外按键（保持原样）
	-----------------------------------------------------------------
	M.setup_extra_keymaps(bufnr)
end

---------------------------------------------------------------------
-- 额外键位（原样保留 + 新增删除任务联动）
---------------------------------------------------------------------
function M.setup_extra_keymaps(bufnr)
	-- 快速保存
	vim.keymap.set("n", "<C-s>", function()
		local autosave = module.get("core.autosave")
		autosave.flush(bufnr) -- 立即保存，无延迟
	end, { buffer = bufnr, desc = "保存TODO文件" })

	-----------------------------------------------------------------
	-- 增强版：支持多 {#id} + 可视模式批量删除同步
	-----------------------------------------------------------------
	vim.keymap.set({ "n", "v" }, "<c-cr>", function()
		local manager = module.get("manager")
		local bufnr = vim.api.nvim_get_current_buf()

		-- 1. 获取删除范围（支持可视模式）
		local mode = vim.fn.mode()
		local start_lnum, end_lnum

		if mode == "v" or mode == "V" then
			start_lnum = vim.fn.line("v")
			end_lnum = vim.fn.line(".")
			if start_lnum > end_lnum then
				start_lnum, end_lnum = end_lnum, start_lnum
			end
		else
			start_lnum = vim.fn.line(".")
			end_lnum = start_lnum
		end

		-- 2. 收集所有 {#id}
		local ids = {}
		local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)

		for _, line in ipairs(lines) do
			for id in line:gmatch("{#(%w+)}") do
				table.insert(ids, id)
			end
		end

		-- 3. 同步删除所有 ID（代码标记 + store）
		for _, id in ipairs(ids) do
			pcall(function()
				manager.on_todo_deleted(id)
			end)
		end

		-- 4. 删除 TODO 行（不模拟 dd，直接删）
		vim.api.nvim_buf_set_lines(bufnr, start_lnum - 1, end_lnum, false, {})

		-- 5. 自动保存 TODO 文件
		local autosave = module.get("core.autosave")
		autosave.request_save(bufnr)
	end, { buffer = bufnr, desc = "删除任务并同步代码标记（dT）" })
end

---------------------------------------------------------------------
-- 通知 API
---------------------------------------------------------------------
function M.show_notification(msg, level)
	show_notification(msg, level)
end

return M
