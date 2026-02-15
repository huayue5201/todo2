-- lua/todo2/keymaps/handlers.lua
--- @module todo2.keymaps.handlers

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local line_analyzer = require("todo2.utils.line_analyzer") -- ⭐ 新增
local creation = require("todo2.creation")
local store_link = require("todo2.store.link")
local state_manager = require("todo2.core.state_manager")
local status_module = require("todo2.status")
local deleter = require("todo2.link.deleter")
local format = require("todo2.utils.format")
local input_ui = require("todo2.ui.input")
local parser = require("todo2.core.parser")
local events_mod = require("todo2.core.events")
local ui = require("todo2.ui")
local operations = require("todo2.ui.operations")
local link = require("todo2.link")
local link_viewer = require("todo2.link.viewer")
local file_manager = require("todo2.ui.file_manager")

---------------------------------------------------------------------
-- 辅助函数（替代 helpers 的部分功能）
---------------------------------------------------------------------
local function get_current_buffer_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local is_todo_file = filename:match("%.todo%.md$") ~= nil

	local win_id = vim.api.nvim_get_current_win()
	local config = vim.api.nvim_win_get_config(win_id)
	local is_float_window = config.relative ~= ""

	return {
		bufnr = bufnr,
		win_id = win_id,
		filename = filename,
		is_todo_file = is_todo_file,
		is_float_window = is_float_window,
	}
end

local function feedkeys(keys, mode)
	mode = mode or "n"
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), mode, false)
end

local function safe_close_window(win_id)
	if vim.api.nvim_win_is_valid(win_id) then
		vim.api.nvim_win_close(win_id, true)
	end
end

---------------------------------------------------------------------
-- 状态相关处理器
---------------------------------------------------------------------
function M.start_unified_creation()
	local context = {
		code_buf = vim.api.nvim_get_current_buf(),
		code_line = vim.fn.line("."),
	}
	creation.start_session(context)
end

function M.toggle_task_status()
	local analysis = line_analyzer.analyze_current_line()
	local info = get_current_buffer_info()

	if info.is_todo_file then
		if analysis.is_todo_task then
			state_manager.toggle_line(info.bufnr, vim.fn.line("."))
		else
			feedkeys("<CR>")
		end
	else
		if analysis.is_code_mark and analysis.id then
			local link = store_link.get_todo(analysis.id, { verify_line = true })
			if link and link.path then
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
		feedkeys("<CR>")
	end
end

function M.show_status_menu()
	status_module.show_status_menu()
end

function M.cycle_status()
	local analysis = line_analyzer.analyze_current_line()
	local info = get_current_buffer_info()

	if info.is_todo_file then
		if analysis.is_todo_task then
			status_module.cycle_status()
		else
			feedkeys("<S-CR>")
		end
	else
		if analysis.is_code_mark and analysis.id then
			local link = store_link.get_todo(analysis.id, { verify_line = true })
			if link and link.path then
				local todo_path = vim.fn.fnamemodify(link.path, ":p")
				local todo_bufnr = vim.fn.bufnr(todo_path)
				if todo_bufnr == -1 then
					vim.fn.bufload(todo_bufnr)
				end
				local current_bufnr = info.bufnr
				local current_win = info.win_id
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
		feedkeys("<S-CR>")
	end
end

---------------------------------------------------------------------
-- 删除相关处理器
---------------------------------------------------------------------
function M.smart_delete()
	local info = get_current_buffer_info()
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

		local analysis = line_analyzer.analyze_lines(info.bufnr, start_lnum, end_lnum)
		if not analysis.has_markers then
			feedkeys("<BS>")
			return
		end
		vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, end_lnum, false, {})
		if #analysis.ids > 0 then
			deleter.batch_delete_todo_links(analysis.ids, {
				todo_bufnr = info.bufnr,
				todo_file = info.filename,
			})
		end
	else
		local analysis = line_analyzer.analyze_current_line()
		if analysis.is_code_mark and analysis.id then
			-- 检查任务是否为归档状态
			local todo_link = store_link.get_todo(analysis.id, { verify_line = false })
			if todo_link and todo_link.status == "archived" then
				-- 归档任务：使用归档专用删除
				deleter.archive_code_link(analysis.id)
				vim.notify("📦 归档任务代码标记已物理删除（存储记录保留）", vim.log.levels.INFO)
			else
				-- 非归档任务：正常删除
				deleter.delete_code_link()
			end
		else
			feedkeys("<BS>")
		end
	end
end

---------------------------------------------------------------------
-- 任务编辑处理器
---------------------------------------------------------------------
function M.edit_task_from_code()
	local analysis = line_analyzer.analyze_current_line()
	if not analysis.is_code_mark or not analysis.id then
		feedkeys("e", "n")
		return
	end

	local id = analysis.id
	if not store_link then
		vim.notify("store.link 模块未加载", vim.log.levels.ERROR)
		return
	end

	local todo_link = store_link.get_todo(id, { verify_line = true })
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
	local parsed = format.parse_task_line(old_line)
	if not parsed then
		vim.notify("当前行不是有效的任务行", vim.log.levels.ERROR)
		return
	end

	input_ui.prompt_multiline({
		title = "Edit Task",
		default = parsed.content or "",
		max_chars = 1000,
		width = 70,
		height = 8,
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
		if parser then
			parser.invalidate_cache(path)
		end
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
	safe_close_window(win_id)
end

function M.ui_refresh()
	local info = get_current_buffer_info()
	if ui and ui.refresh then
		ui.refresh(info.bufnr)
		vim.cmd("redraw")
	end
end

function M.ui_insert_task()
	local info = get_current_buffer_info()
	operations.insert_task("新任务", 0, info.bufnr, ui)
end

function M.ui_insert_subtask()
	local info = get_current_buffer_info()
	operations.insert_task("新任务", 2, info.bufnr, ui)
end

function M.ui_insert_sibling()
	local info = get_current_buffer_info()
	operations.insert_task("新任务", 0, info.bufnr, ui)
end

function M.ui_toggle_selected()
	local info = get_current_buffer_info()
	local win = vim.fn.bufwinid(info.bufnr)
	if win == -1 then
		vim.notify("未在窗口中找到缓冲区", vim.log.levels.ERROR)
		return 0
	end
	local changed = operations.toggle_selected_tasks(info.bufnr, win)
	return changed
end

---------------------------------------------------------------------
-- 链接相关处理器
---------------------------------------------------------------------
function M.jump_dynamic()
	local analysis = line_analyzer.analyze_current_line()
	if analysis.is_mark then
		link.jump_dynamic()
	else
		feedkeys("<tab>")
	end
end

function M.preview_content()
	local analysis = line_analyzer.analyze_current_line()
	if analysis.is_mark then
		local info = get_current_buffer_info()
		if info.is_todo_file then
			link.preview_code()
		else
			link.preview_todo()
		end
	else
		local info = get_current_buffer_info()
		if vim.lsp.buf_get_clients(info.bufnr) and #vim.lsp.buf_get_clients(info.bufnr) > 0 then
			vim.lsp.buf.hover()
		else
			feedkeys("K")
		end
	end
end

function M.show_project_links_qf()
	link_viewer.show_project_links_qf()
end

function M.show_buffer_links_loclist()
	link_viewer.show_buffer_links_loclist()
end

---------------------------------------------------------------------
-- 文件管理处理器
---------------------------------------------------------------------
function M.open_todo_float()
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "float", 1, { enter_insert = false })
		end
	end)
end

function M.open_todo_split_horizontal()
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
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "edit", 1, { enter_insert = false })
		end
	end)
end

function M.create_todo_file()
	ui.create_todo_file()
end

function M.delete_todo_file()
	ui.select_todo_file("current", function(choice)
		if choice then
			file_manager.delete_todo_file(choice.path)
		end
	end)
end

return M
