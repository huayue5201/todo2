--- File: /Users/lijia/todo2/lua/todo2/keymaps/handlers.lua ---
-- lua/todo2/keymaps/handlers.lua
--- @module todo2.keymaps.handlers
--- @brief 统一的按键处理器实现

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 通用工具函数
---------------------------------------------------------------------
local function safe_call(fn, ...)
	local success, result = pcall(fn, ...)
	if not success then
		vim.notify("按键处理失败: " .. result, vim.log.levels.ERROR)
	end
	return success, result
end

local function get_current_buffer_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local is_todo_file = filename:match("%.todo%.md$")
	local is_float_window = false

	local win_id = vim.api.nvim_get_current_win()
	local config = vim.api.nvim_win_get_config(win_id)
	if config.relative ~= "" then
		is_float_window = true
	end

	return {
		bufnr = bufnr,
		win_id = win_id,
		filename = filename,
		is_todo_file = is_todo_file,
		is_float_window = is_float_window,
	}
end

---------------------------------------------------------------------
-- 核心：状态相关处理器
---------------------------------------------------------------------

-- 状态切换处理器（统一实现）
function M.toggle_task_status()
	local info = get_current_buffer_info()

	if info.is_todo_file then
		-- TODO文件中：直接切换当前行状态
		local core = module.get("core")
		core.toggle_line(info.bufnr, vim.fn.line("."))
	else
		-- 代码文件中：通过链接跳转切换
		local line = vim.fn.getline(".")
		local tag, id = line:match("(%u+):ref:(%w+)")

		if id then
			local store = module.get("store")
			local link = store.get_todo_link(id, { force_relocate = true })

			if link and link.path then
				local state_manager = module.get("core.state_manager")
				local todo_path = vim.fn.fnamemodify(link.path, ":p")
				local todo_bufnr = vim.fn.bufnr(todo_path)

				if todo_bufnr == -1 then
					todo_bufnr = vim.fn.bufadd(todo_path)
					vim.fn.bufload(todo_bufnr)
				end

				-- 切换到状态
				state_manager.toggle_line(todo_bufnr, link.line or 1)
			end
		else
			-- 没有标记：执行默认回车
			return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
		end
	end
end

-- 显示状态菜单
function M.show_status_menu()
	local core_status = require("todo2.core.status")
	core_status.show_status_menu()
end

-- 循环切换状态
function M.cycle_status()
	local core_status = require("todo2.core.status")
	core_status.cycle_status()
end

---------------------------------------------------------------------
-- 核心：删除相关处理器
---------------------------------------------------------------------
-- 智能删除处理器（统一实现）
function M.smart_delete()
	local info = get_current_buffer_info()
	local mode = vim.fn.mode()

	if info.is_todo_file then
		-- TODO文件中：删除任务并同步代码
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

		-- 收集所有ID
		local ids = {}
		local lines = vim.api.nvim_buf_get_lines(info.bufnr, start_lnum - 1, end_lnum, false)

		for _, line in ipairs(lines) do
			for id in line:gmatch("{#(%w+)}") do
				table.insert(ids, id)
			end
		end

		-- ⭐ 关键修改：直接删除行，然后统一处理删除逻辑
		-- 1. 首先删除TODO行
		vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, end_lnum, false, {})

		-- 2. 批量删除代码标记（使用一个函数调用，避免循环中的多次事件触发）
		if #ids > 0 then
			-- 使用批量删除函数，避免每个ID都触发事件
			local deleter = module.get("link.deleter")
			deleter.batch_delete_todo_links(ids, {
				todo_bufnr = info.bufnr,
				todo_file = info.filename,
			})
		end
	else
		-- 代码文件中：删除标记
		module.get("link.deleter").delete_code_link()
	end
end

---------------------------------------------------------------------
-- UI相关处理器
---------------------------------------------------------------------

-- 关闭窗口
function M.ui_close_window()
	local win_id = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_is_valid(win_id) then
		vim.api.nvim_win_close(win_id, true)
	end
end

-- 刷新显示
function M.ui_refresh()
	local info = get_current_buffer_info()
	local ui = module.get("ui")
	if ui and ui.refresh then
		ui.refresh(info.bufnr)
		vim.cmd("redraw")
	end
end

-- 新建任务
function M.ui_insert_task()
	local info = get_current_buffer_info()
	local operations = module.get("ui.operations")
	operations.insert_task("新任务", 0, info.bufnr, module.get("ui"))
end

-- 新建子任务
function M.ui_insert_subtask()
	local info = get_current_buffer_info()
	local operations = module.get("ui.operations")
	operations.insert_task("新任务", 2, info.bufnr, module.get("ui"))
end

-- 新建平级任务
function M.ui_insert_sibling()
	local info = get_current_buffer_info()
	local operations = module.get("ui.operations")
	operations.insert_task("新任务", 0, info.bufnr, module.get("ui"))
end

-- 批量切换任务状态
function M.ui_toggle_selected()
	local info = get_current_buffer_info()
	local win = vim.fn.bufwinid(info.bufnr)

	if win == -1 then
		vim.notify("未在窗口中找到缓冲区", vim.log.levels.ERROR)
		return 0
	end

	local operations = module.get("ui.operations")
	local changed = operations.toggle_selected_tasks(info.bufnr, win)
	return changed
end

-- 插入模式切换任务状态
function M.ui_toggle_insert()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)
	local info = get_current_buffer_info()
	local core = module.get("core")
	core.toggle_line(info.bufnr, vim.fn.line("."))
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
end

---------------------------------------------------------------------
-- 链接相关处理器
---------------------------------------------------------------------

-- 创建链接
function M.create_link()
	module.get("link").create_link()
end

-- 动态跳转
function M.jump_dynamic()
	module.get("link").jump_dynamic()
end

-- 预览内容
function M.preview_content()
	local line = vim.fn.getline(".")
	local link = module.get("link")

	if line:match("(%u+):ref:(%w+)") then
		link.preview_todo()
	elseif line:match("{#(%w+)}") then
		link.preview_code()
	else
		vim.lsp.buf.hover()
	end
end

-- 从代码中创建子任务
function M.create_child_from_code()
	module.get("link.child").create_child_from_code()
end

-- 显示所有双链标记 (QuickFix)
function M.show_project_links_qf()
	module.get("link.viewer").show_project_links_qf()
end

-- 显示当前缓冲区双链标记 (LocList)
function M.show_buffer_links_loclist()
	module.get("link.viewer").show_buffer_links_loclist()
end

-- 修复当前缓冲区孤立的标记
function M.cleanup_orphan_links_in_buffer()
	module.get("link.cleaner").cleanup_orphan_links_in_buffer()
end

---------------------------------------------------------------------
-- 文件管理处理器
---------------------------------------------------------------------

-- 浮窗打开 TODO 文件
function M.open_todo_float()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "float", 1, { enter_insert = false })
		end
	end)
end

-- 水平分割打开 TODO 文件
function M.open_todo_split_horizontal()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "split", 1, {
				enter_insert = false,
				split_direction = "horizontal",
			})
		end
	end)
end

-- 垂直分割打开 TODO 文件
function M.open_todo_split_vertical()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "split", 1, {
				enter_insert = false,
				split_direction = "vertical",
			})
		end
	end)
end

-- 编辑模式打开 TODO 文件
function M.open_todo_edit()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "edit", 1, { enter_insert = false })
		end
	end)
end

-- 创建 TODO 文件
function M.create_todo_file()
	module.get("ui").create_todo_file()
end

-- 删除 TODO 文件
function M.delete_todo_file()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.delete_todo_file(choice.path)
		end
	end)
end

---------------------------------------------------------------------
-- 存储维护处理器
---------------------------------------------------------------------

-- 清理过期存储数据
function M.cleanup_expired_links()
	local config = module.get("config").get_store()
	local store = module.get("store")
	local days = (config and config.cleanup_days_old) or 30
	local cleaned = store.cleanup_expired(days)
	if cleaned then
		local ui = module.get("ui")
		if ui and ui.show_notification then
			ui.show_notification("清理了 " .. cleaned .. " 条过期数据")
		else
			vim.notify("清理了 " .. cleaned .. " 条过期数据")
		end
	end
end

-- 验证所有链接
function M.validate_all_links()
	local config = module.get("config").get_store()
	local store = module.get("store")
	local results = store.validate_all_links({
		verbose = config and config.verbose_logging,
		force = false,
	})
	if results and results.summary then
		local ui = module.get("ui")
		if ui and ui.show_notification then
			ui.show_notification(results.summary)
		else
			vim.notify(results.summary)
		end
	end
end

---------------------------------------------------------------------
-- 快速保存处理器
---------------------------------------------------------------------

-- 快速保存 TODO 文件
function M.quick_save()
	local info = get_current_buffer_info()
	local autosave = module.get("core.autosave")
	autosave.flush(info.bufnr) -- 立即保存，无延迟
end

---------------------------------------------------------------------
-- 工具函数：获取所有处理器
---------------------------------------------------------------------
function M.get_all_handlers()
	return M
end

return M
