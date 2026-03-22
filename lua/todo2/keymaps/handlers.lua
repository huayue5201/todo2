-- lua/todo2/keymaps/handlers.lua
-- 纯功能平移：使用新接口获取任务数据

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local line_analyzer = require("todo2.utils.line_analyzer")
local creation = require("todo2.creation.manager")
local core = require("todo2.store.link.core") -- 新增
local state_manager = require("todo2.core.state_manager")
local status_module = require("todo2.status")
local deleter = require("todo2.task.deleter")
local format = require("todo2.utils.format")
local input_ui = require("todo2.ui.input")
local events_mod = require("todo2.core.events")
local ui = require("todo2.ui")
local operations = require("todo2.creation.actions.operations")
local link_jumper = require("todo2.task.jumper")
local link_preview = require("todo2.task.preview")
local link_viewer = require("todo2.task.viewer")
local file_manager = require("todo2.ui.file_manager")
local id_utils = require("todo2.utils.id")
local scheduler = require("todo2.render.scheduler")
local autosave = require("todo2.core.autosave")

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

local function safe_close_window(win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return false
	end

	local wins = vim.api.nvim_list_wins()

	if #wins <= 1 then
		return false
	end

	local buf = vim.api.nvim_win_get_buf(win)
	local buf_wins = vim.fn.win_findbuf(buf)

	if #buf_wins <= 1 and #wins <= 2 then
		return false
	end

	pcall(vim.api.nvim_win_close, win, true)
	return true
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

	------------------------------------------------------------------
	-- 情况 1：在 TODO 文件中（普通任务需要改文本）
	------------------------------------------------------------------
	if info.is_todo_file and analysis.is_todo_task then
		state_manager.toggle_line(info.bufnr, vim.fn.line("."))
		return
	end

	------------------------------------------------------------------
	-- 情况 2：在代码文件中（纯数据，不加载、不跳 buffer）
	------------------------------------------------------------------
	if not info.is_todo_file and analysis.is_code_mark and analysis.id then
		state_manager.toggle_line(nil, nil, { id = analysis.id })
		return
	end

	------------------------------------------------------------------
	-- 情况 3：不是任务行
	------------------------------------------------------------------
	feedkeys("<CR>")
end

function M.show_status_menu()
	status_module.show_status_menu()
end

function M.cycle_status()
	local analysis = line_analyzer.analyze_current_line()
	if not analysis or not analysis.id then
		feedkeys("<S-CR>")
		return
	end

	local core_status = require("todo2.core.status")

	local task = core.get_task(analysis.id)
	if not task then
		feedkeys("<S-CR>")
		return
	end

	local current_status = task.core.status or "normal"
	local new_status = status_module.get_next_status(current_status)

	-- 直接更新，不再弹通知
	core_status.update(analysis.id, new_status, "cycle_status")
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

		local line = vim.api.nvim_buf_get_lines(info.bufnr, start_lnum - 1, start_lnum, false)[1]
		if line and line:match("^%s*- %[[^]]%]") and not id_utils.contains_code_mark(line) then
			vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, end_lnum, false, {})
			autosave.request_save(info.bufnr)
			return
		end

		local analysis = line_analyzer.analyze_lines(info.bufnr, start_lnum, end_lnum)

		if #analysis.ids > 0 then
			-- ⭐ 接收2个返回值
			local success, _ = deleter.delete_by_ids(analysis.ids)
			if not success then
				vim.notify("删除失败", vim.log.levels.WARN)
			end
		else
			vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, end_lnum, false, {})
			autosave.request_save(info.bufnr)
		end
	else
		local analysis = line_analyzer.analyze_current_line()
		if analysis.is_code_mark and analysis.id then
			-- ⭐ 接收2个返回值
			local success, _ = deleter.delete_current_code_mark()
			if not success then
				vim.notify("删除代码标记失败", vim.log.levels.WARN)
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
	local task = core.get_task(id)
	if not task or not task.locations.todo then
		vim.notify("未找到对应的 TODO 任务", vim.log.levels.ERROR)
		return
	end

	local path = task.locations.todo.path
	local line_num = task.locations.todo.line

	local lines = scheduler.get_file_lines(path, false)
	if not lines or #lines == 0 or line_num < 1 or line_num > #lines then
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

		-- 更新内部格式
		task.core.content = new_content
		task.core.content_hash = require("todo2.utils.hash").hash(new_content)
		task.timestamps.updated = os.time()
		core.save_task(id, task)

		-- 更新文件内容
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

		scheduler.invalidate_cache(path)

		if events_mod then
			events_mod.on_state_changed({
				source = "edit_task_from_code",
				file = path,
				ids = { id },
			})
		end
	end)
end

---------------------------------------------------------------------
-- UI相关处理器（保持不变）
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
-- 链接相关处理器（保持不变）
---------------------------------------------------------------------
function M.jump_dynamic()
	local analysis = line_analyzer.analyze_current_line()
	if analysis.is_mark then
		link_jumper.jump_dynamic()
	else
		feedkeys("<tab>")
	end
end

function M.preview_content()
	local analysis = line_analyzer.analyze_current_line()
	if analysis.is_mark then
		local info = get_current_buffer_info()
		if info.is_todo_file then
			link_preview.preview_code()
		else
			link_preview.preview_todo()
		end
		return
	end
end

function M.show_project_links_qf()
	link_viewer.show_project_links_qf()
end

function M.show_buffer_links_loclist()
	link_viewer.show_buffer_links_loclist()
end

---------------------------------------------------------------------
-- 文件管理处理器（保持不变）
---------------------------------------------------------------------
function M.open_todo_float()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "float", 1, { enter_insert = false })
		end
	end)
end

function M.open_todo_split_horizontal()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "split", 1, {
				enter_insert = false,
				split_direction = "horizontal",
			})
		end
	end)
end

function M.open_todo_split_vertical()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "split", 1, {
				enter_insert = false,
				split_direction = "vertical",
			})
		end
	end)
end

function M.open_todo_edit()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "edit", 1, { enter_insert = false })
		end
	end)
end

function M.create_todo_file()
	file_manager.create_todo_file()
end

function M.rename_todo_file()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			file_manager.rename_todo_file(choice.path)
		end
	end)
end

function M.delete_todo_file()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			file_manager.delete_todo_file(choice.path)
		end
	end)
end

return M
