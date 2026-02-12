-- lua/todo2/keymaps/handlers.lua
--- @module todo2.keymaps.handlers

local M = {}

local module = require("todo2.module")
local helpers = require("todo2.utils.helpers")

local function get_store_module()
	local store_link = module.get("store.link")
	if not store_link then
		error("store.link模块未加载")
	end
	return store_link
end

---------------------------------------------------------------------
-- 状态相关处理器
---------------------------------------------------------------------
function M.start_unified_creation()
	local creation = require("todo2.creation")
	local context = {
		code_buf = vim.api.nvim_get_current_buf(),
		code_line = vim.fn.line("."),
	}
	creation.start_session(context)
end

function M.toggle_task_status()
	local line_analysis = helpers.analyze_current_line()
	local should_execute_default = false

	if line_analysis.info.is_todo_file then
		if line_analysis.is_todo_task then
			local core = module.get("core")
			core.toggle_line(line_analysis.info.bufnr, vim.fn.line("."))
		else
			should_execute_default = true
		end
	else
		if line_analysis.is_code_mark then
			local store = get_store_module()
			local link = store.get_todo(line_analysis.id, { verify_line = true })
			if link and link.path then
				local state_manager = module.get("core.state_manager")
				local todo_path = vim.fn.fnamemodify(link.path, ":p")
				local todo_bufnr = vim.fn.bufnr(todo_path)
				if todo_bufnr == -1 then
					todo_bufnr = vim.fn.bufadd(todo_path)
					vim.fn.bufload(todo_bufnr)
				end
				state_manager.toggle_line(todo_bufnr, link.line or 1)
				return
			end
		end
		should_execute_default = true
	end

	if should_execute_default then
		helpers.feedkeys("<CR>")
	end
end

function M.show_status_menu()
	local status_module = require("todo2.status")
	status_module.show_status_menu()
end

function M.cycle_status()
	local line_analysis = helpers.analyze_current_line()
	local should_execute_default = false

	if line_analysis.info.is_todo_file then
		if line_analysis.is_todo_task then
			local status_module = require("todo2.status")
			status_module.cycle_status()
		else
			should_execute_default = true
		end
	else
		if line_analysis.is_code_mark then
			local store = get_store_module()
			local link = store.get_todo(line_analysis.id, { verify_line = true })
			if link and link.path then
				local status_module = require("todo2.status")
				local todo_path = vim.fn.fnamemodify(link.path, ":p")
				local todo_bufnr = vim.fn.bufnr(todo_path)
				if todo_bufnr == -1 then
					todo_bufnr = vim.fn.bufadd(todo_path)
					vim.fn.bufload(todo_bufnr)
				end
				local current_bufnr = line_analysis.info.bufnr
				local current_win = line_analysis.info.win_id
				vim.cmd("buffer " .. todo_bufnr)
				vim.fn.cursor(link.line or 1, 1)
				status_module.cycle_status()
				if vim.api.nvim_win_is_valid(current_win) then
					vim.api.nvim_set_current_win(current_win)
				end
				if vim.api.nvim_buf_is_valid(current_bufnr) then
					vim.cmd("buffer " .. current_bufnr)
				end
				return
			end
		end
		should_execute_default = true
	end

	if should_execute_default then
		helpers.feedkeys("<S-CR>")
	end
end

---------------------------------------------------------------------
-- 删除相关处理器
---------------------------------------------------------------------
function M.smart_delete()
	local info = helpers.get_current_buffer_info()
	local mode = vim.fn.mode()

	if info.is_todo_file then
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
		local analysis = helpers.analyze_lines(info.bufnr, start_lnum, end_lnum)
		if not analysis.has_markers then
			helpers.feedkeys("<BS>")
			return
		end
		vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, end_lnum, false, {})
		if #analysis.ids > 0 then
			local deleter = module.get("link.deleter")
			deleter.batch_delete_todo_links(analysis.ids, {
				todo_bufnr = info.bufnr,
				todo_file = info.filename,
			})
		end
	else
		local line_analysis = helpers.analyze_current_line()
		if line_analysis.is_code_mark then
			local deleter = module.get("link.deleter")
			deleter.delete_code_link()
		else
			helpers.feedkeys("<BS>")
		end
	end
end

---------------------------------------------------------------------
-- 任务编辑处理器（浮窗多行版）
---------------------------------------------------------------------
function M.edit_task_from_code()
	local line_analysis = helpers.analyze_current_line()
	if not line_analysis.is_code_mark then
		helpers.feedkeys("e", "n")
		return
	end
	local id = line_analysis.id
	local link_mod = module.get("store.link")
	if not link_mod then
		vim.notify("store.link 模块未加载", vim.log.levels.ERROR)
		return
	end
	local todo_link = link_mod.get_todo(id, { verify_line = true })
	if not todo_link then
		vim.notify("未找到对应的 TODO 链接", vim.log.levels.ERROR)
		return
	end
	local path = todo_link.path
	local line_num = todo_link.line
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or not lines or line_num < 1 or line_num > #lines then
		vim.notify("无法读取 TODO 文件或行号无效", vim.log.levels.ERROR)
		return
	end
	local old_line = lines[line_num]
	local format = require("todo2.utils.format")
	local parsed = format.parse_task_line(old_line)
	if not parsed then
		vim.notify("当前行不是有效的任务行", vim.log.levels.ERROR)
		return
	end
	local input_ui = require("todo2.ui.input")
	input_ui.prompt_multiline({
		title = "Edit Task",
		default = parsed.content or "",
		max_chars = 1000,
		width = 70,
		height = 12,
	}, function(new_content)
		if not new_content or new_content == "" then
			return
		end
		new_content = new_content:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
		if new_content == parsed.content then
			return
		end
		local new_line = format.format_task_line({
			indent = parsed.indent,
			checkbox = parsed.checkbox,
			id = parsed.id,
			tag = parsed.tag,
			content = new_content,
		})
		lines[line_num] = new_line
		local write_ok, write_err = pcall(vim.fn.writefile, lines, path)
		if not write_ok then
			vim.notify("写入 TODO 文件失败: " .. tostring(write_err), vim.log.levels.ERROR)
			return
		end
		local parser = module.get("core.parser")
		if parser then
			parser.invalidate_cache(path)
		end
		local events_mod = module.get("core.events")
		if events_mod then
			events_mod.on_state_changed({
				source = "edit_task_from_code",
				file = path,
				ids = { id },
			})
		end
		vim.notify("✅ 任务内容已更新", vim.log.levels.INFO)
	end)
end

---------------------------------------------------------------------
-- UI相关处理器
---------------------------------------------------------------------
function M.ui_close_window()
	local win_id = vim.api.nvim_get_current_win()
	helpers.safe_close_window(win_id)
end

function M.ui_refresh()
	local info = helpers.get_current_buffer_info()
	local ui = module.get("ui")
	if ui and ui.refresh then
		ui.refresh(info.bufnr)
		vim.cmd("redraw")
	end
end

function M.ui_insert_task()
	local info = helpers.get_current_buffer_info()
	local operations = module.get("ui.operations")
	operations.insert_task("新任务", 0, info.bufnr, module.get("ui"))
end

function M.ui_insert_subtask()
	local info = helpers.get_current_buffer_info()
	local operations = module.get("ui.operations")
	operations.insert_task("新任务", 2, info.bufnr, module.get("ui"))
end

function M.ui_insert_sibling()
	local info = helpers.get_current_buffer_info()
	local operations = module.get("ui.operations")
	operations.insert_task("新任务", 0, info.bufnr, module.get("ui"))
end

function M.ui_toggle_selected()
	local info = helpers.get_current_buffer_info()
	local win = vim.fn.bufwinid(info.bufnr)
	if win == -1 then
		vim.notify("未在窗口中找到缓冲区", vim.log.levels.ERROR)
		return 0
	end
	local operations = module.get("ui.operations")
	local changed = operations.toggle_selected_tasks(info.bufnr, win)
	return changed
end

---------------------------------------------------------------------
-- 链接相关处理器
---------------------------------------------------------------------
function M.jump_dynamic()
	local line_analysis = helpers.analyze_current_line()
	local should_execute_default = false
	if line_analysis.is_mark then
		module.get("link").jump_dynamic()
	else
		should_execute_default = true
	end
	if should_execute_default then
		helpers.feedkeys("<tab>")
	end
end

function M.preview_content()
	local line_analysis = helpers.analyze_current_line()
	local link = module.get("link")
	if line_analysis.is_mark then
		if line_analysis.info.is_todo_file then
			link.preview_code()
		else
			link.preview_todo()
		end
	else
		local info = line_analysis.info
		if vim.lsp.buf_get_clients(info.bufnr) and #vim.lsp.buf_get_clients(info.bufnr) > 0 then
			vim.lsp.buf.hover()
		else
			helpers.feedkeys("K")
		end
	end
end

function M.show_project_links_qf()
	module.get("link.viewer").show_project_links_qf()
end

function M.show_buffer_links_loclist()
	module.get("link.viewer").show_buffer_links_loclist()
end

---------------------------------------------------------------------
-- 文件管理处理器
---------------------------------------------------------------------
function M.open_todo_float()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "float", 1, { enter_insert = false })
		end
	end)
end

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

function M.open_todo_edit()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "edit", 1, { enter_insert = false })
		end
	end)
end

function M.create_todo_file()
	module.get("ui").create_todo_file()
end

function M.delete_todo_file()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.delete_todo_file(choice.path)
		end
	end)
end

---------------------------------------------------------------------
-- 链式标记处理器
---------------------------------------------------------------------
function M.create_chain_from_code()
	local chain_module = module.get("link.chain")
	if chain_module and chain_module.create_chain_from_code then
		chain_module.create_chain_from_code()
	else
		vim.notify("链式标记模块未加载", vim.log.levels.ERROR)
	end
end

return M
