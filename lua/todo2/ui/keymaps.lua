-- lua/todo2/ui/keymaps.lua
--- @module todo2.ui.keymaps

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 键位设置函数（只负责绑定 handler，不再声明按键）
---------------------------------------------------------------------
function M.setup_keymaps(bufnr, win, ui_module)
	-- 通过模块管理器获取依赖
	local keymaps_main = module.get("keymaps")
	local keymap_defs = keymaps_main.ui_keymaps

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
	-- 绑定 UI 按键（从 keymaps.lua 读取）
	-----------------------------------------------------------------
	for key, def in pairs(keymap_defs) do
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
	M.setup_extra_keymaps(bufnr, win, ui_module)
end

---------------------------------------------------------------------
-- 额外键位（原样保留 + 新增删除任务联动）
---------------------------------------------------------------------
function M.setup_extra_keymaps(bufnr, win, ui_module)
	-- 切换窗口模式的快捷键
	vim.keymap.set("n", "<C-w>f", function()
		if ui_module and ui_module.switch_to_float then
			ui_module.switch_to_float(bufnr, win)
		end
	end, { buffer = bufnr, desc = "切换到浮窗模式" })

	vim.keymap.set("n", "<C-w>s", function()
		if ui_module and ui_module.switch_to_split then
			ui_module.switch_to_split(bufnr, win, "horizontal")
		end
	end, { buffer = bufnr, desc = "切换到水平分割" })

	vim.keymap.set("n", "<C-w>v", function()
		if ui_module and ui_module.switch_to_split then
			ui_module.switch_to_split(bufnr, win, "vertical")
		end
	end, { buffer = bufnr, desc = "切换到垂直分割" })

	-- 快速保存
	vim.keymap.set("n", "<C-s>", function()
		vim.cmd("write")
		if ui_module and ui_module.refresh then
			ui_module.refresh(bufnr)
		end
	end, { buffer = bufnr, desc = "保存TODO文件" })

	-- 快速导航
	vim.keymap.set("n", "]]", function()
		vim.cmd("normal! }")
		vim.cmd("normal! zz")
	end, { buffer = bufnr, desc = "下一个任务组" })

	vim.keymap.set("n", "[[", function()
		vim.cmd("normal! {")
		vim.cmd("normal! zz")
	end, { buffer = bufnr, desc = "上一个任务组" })

	-- 折叠相关（使用 pcall 防止 E490 报错）
	vim.keymap.set("n", "za", function()
		pcall(vim.cmd, "normal! za")
	end, { buffer = bufnr, desc = "切换折叠" })

	vim.keymap.set("n", "zR", function()
		pcall(vim.cmd, "normal! zR")
	end, { buffer = bufnr, desc = "展开所有折叠" })

	vim.keymap.set("n", "zM", function()
		pcall(vim.cmd, "normal! zM")
	end, { buffer = bufnr, desc = "折叠所有" })

	-----------------------------------------------------------------
	-- 增强版：支持多 {#id} + 可视模式批量删除同步
	-----------------------------------------------------------------
	vim.keymap.set({ "n", "v" }, "do", function()
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
return M
