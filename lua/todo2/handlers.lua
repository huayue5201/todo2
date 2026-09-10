-- lua/todo2/keymaps/handlers.lua
-- 精简版：移除代码文件标记行依赖

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local line = require("todo2.utils.line")
local core = require("todo2.store.link.core")
local state_manager = require("todo2.core.state_manager")
local status_module = require("todo2.status")
local deleter = require("todo2.task.deleter")
local format = require("todo2.utils.format")
local input_ui = require("todo2.ui.input")
local events_mod = require("todo2.core.events")
local ui = require("todo2.ui")
local operations = require("todo2.creation.actions.operations")
local link_preview = require("todo2.task.preview")
local link_viewer = require("todo2.task.viewer")
local file_manager = require("todo2.ui.file_manager")
local id_utils = require("todo2.utils.id")
local scheduler = require("todo2.render.scheduler")
local autosave = require("todo2.core.autosave")
local index = require("todo2.store.index")

---------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------
--- 获取当前窗口信息,判断窗口类型,普通窗口or浮动窗口.
---@return table
-- TODO: 窗口信息是否需要统一为一个公共方法.
local function get_current_buffer_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local is_todo_file = string.match(filename, "%.todo%.md$") ~= nil

	local win_id = vim.api.nvim_get_current_win()
	local win_config = vim.api.nvim_win_get_config(win_id)
	local is_float_window = win_config.relative ~= ""

	return {
		bufnr = bufnr,
		win_id = win_id,
		filename = filename,
		is_todo_file = is_todo_file,
		is_float_window = is_float_window,
	}
end

--- 向 Neovim 发送按键序列.
---@param keys string 要发送的按键序列
---@param mode string|nil 按键模式 (默认 "n")
local function feedkeys(keys, mode)
	mode = mode or "n"
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), mode, false)
end

--- 安全关闭窗口,避免关闭最后一个窗口或导致缓冲区丢失.
---@param win number 窗口 ID
---@return boolean 是否成功关闭窗口
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

--- 读取文件内容（优先从已加载的缓冲区读取）.
---@param path string 文件路径
---@return string[]|nil 文件行数组,读取失败返回 nil
local function read_file_lines(path)
	if not path or path == "" then
		return nil
	end

	local bufnr = vim.fn.bufnr(path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if ok and lines then
		return lines
	end

	return nil
end

--- 获取代码光标位置的任务.
---@param bufnr number 缓冲区 ID
---@param line number 行号 (1-based)
---@return table|nil 任务对象,未找到返回 nil
local function get_task_at_cursor(bufnr, line)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return nil
	end

	local tasks = index.find_code_links_by_file(path)
	for _, task in ipairs(tasks) do
		if task.locations.code and task.locations.code.line == line then
			return task
		end
	end
	return nil
end

--- 切换任务状态（在 TODO 文件或代码文件中）.
function M.toggle_task_status()
	local analysis = line.analyze_current_line()
	local info = get_current_buffer_info()

	-- 情况 1：TODO 文件中的任务行 - 直接用 ID 调用 state_manager
	if analysis.id then
		state_manager.toggle_line(nil, nil, { id = analysis.id })
		return
	end

	-- 情况 2：代码文件中的任务
	if not info.is_todo_file then
		local task = get_task_at_cursor(info.bufnr, vim.fn.line("."))
		if task then
			state_manager.toggle_line(nil, nil, { id = task.id })
			return
		end
	end

	feedkeys("<CR>")
end

--- 显示状态菜单.
function M.show_status_menu()
	status_module.show_status_menu()
end

--- 循环切换任务状态（normal -> doing -> done）.
function M.cycle_status()
	local analysis = line.analyze_current_line()
	local info = get_current_buffer_info()
	local id = nil

	-- TODO 文件：从解析获取 ID
	if info.is_todo_file and analysis.id then
		id = analysis.id
		-- 代码文件：从存储查询
	elseif not info.is_todo_file then
		local task = get_task_at_cursor(info.bufnr, vim.fn.line("."))
		if task then
			id = task.id
		end
	end

	if not id then
		feedkeys("<S-CR>")
		return
	end

	local core_status = require("todo2.core.status")
	local task = core.get_task(id)
	if not task then
		feedkeys("<S-CR>")
		return
	end

	local current_status = task.core.status or "normal"
	local new_status = status_module.get_next_status(current_status)

	core_status.update(id, new_status, "cycle_status")
end

---------------------------------------------------------------------
-- 删除相关处理器
---------------------------------------------------------------------
--- 智能删除：删除任务或删除任务行（支持可视模式）.
-- FIX: 删除任务后,没有立即刷新渲染.
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
		-- 普通任务（无 ID）直接删除行
		if line and line:match("^%s*- %[[^]]%]") and not id_utils.contains_mark(line) then
			vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, end_lnum, false, {})
			autosave.request_save(info.bufnr)
			return
		end

		local analysis = line.analyze_lines(info.bufnr, start_lnum, end_lnum)

		if #analysis.ids > 0 then
			local success, _ = deleter.delete_by_ids(analysis.ids)
			if not success then
				vim.notify("删除失败", vim.log.levels.WARN)
			end
		else
			vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, end_lnum, false, {})
			autosave.request_save(info.bufnr)
		end
	else
		-- 代码文件：删除任务（不删除代码行）
		local task = get_task_at_cursor(info.bufnr, vim.fn.line("."))
		if task then
			local success, _ = deleter.delete_by_ids({ task.id })
			if not success then
				vim.notify("删除任务失败", vim.log.levels.WARN)
			end
		else
			feedkeys("<BS>")
		end
	end
end

---------------------------------------------------------------------
-- 任务编辑处理器
---------------------------------------------------------------------
--- 从代码文件编辑关联的 TODO 任务内容.
function M.edit_task_from_code()
	local info = get_current_buffer_info()
	local task = get_task_at_cursor(info.bufnr, vim.fn.line("."))

	if not task or not task.locations.todo then
		feedkeys("e", "n")
		return
	end

	local id = task.id
	local path = task.locations.todo.path
	local line_num = task.locations.todo.line

	local lines = read_file_lines(path)
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

		-- 更新存储
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
				changed_ids = { id },
			})
		end
	end)
end

---------------------------------------------------------------------
-- UI相关处理器
---------------------------------------------------------------------
--- 关闭当前浮动窗口（安全关闭）.
function M.ui_close_window()
	local win_id = vim.api.nvim_get_current_win()
	safe_close_window(win_id)
end

--- 刷新当前缓冲区.
function M.ui_refresh()
	local info = get_current_buffer_info()
	if ui and ui.refresh then
		ui.refresh(info.bufnr)
		vim.cmd("redraw")
	end
end

--- 在当前行插入同级任务.
function M.ui_insert_task()
	local info = get_current_buffer_info()
	operations.insert_task("新任务", 0, info.bufnr, ui)
end

--- 在当前行插入子任务（缩进 2 级）.
function M.ui_insert_subtask()
	local info = get_current_buffer_info()
	operations.insert_task("新任务", 2, info.bufnr, ui)
end

--- 在当前行插入同级任务（同 ui_insert_task）.
function M.ui_insert_sibling()
	local info = get_current_buffer_info()
	operations.insert_task("新任务", 0, info.bufnr, ui)
end

--- 切换选中任务的状态.
---@return number 改变的任务数量
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

--- 预览任务内容（代码预览或 TODO 预览）.
function M.preview_content()
	local info = get_current_buffer_info()
	local task = nil

	if info.is_todo_file then
		local analysis = line.analyze_current_line()
		if analysis.id then
			task = core.get_task(analysis.id)
		end
	else
		task = get_task_at_cursor(info.bufnr, vim.fn.line("."))
	end

	if task then
		if info.is_todo_file then
			link_preview.preview_code()
		else
			link_preview.preview_todo()
		end
		return
	end
end

--- 在 quickfix 中显示项目所有链接.
function M.show_project_links_qf()
	link_viewer.show_project_links_qf()
end

--- 在 location list 中显示当前缓冲区链接.
function M.show_buffer_links_loclist()
	link_viewer.show_buffer_links_loclist()
end

---------------------------------------------------------------------
-- 文件管理处理器
---------------------------------------------------------------------
--- 打开 TODO 文件（浮动窗口）.
function M.open_todo_float()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "float", 1, { enter_insert = false })
		end
	end)
end

--- 打开 TODO 文件（水平分割）.
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

--- 打开 TODO 文件（垂直分割）.
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

--- 打开 TODO 文件（当前窗口编辑）.
function M.open_todo_edit()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "edit", 1, { enter_insert = false })
		end
	end)
end

--- 创建新的 TODO 文件.
function M.create_todo_file()
	file_manager.create_todo_file()
end

--- 重命名 TODO 文件.
function M.rename_todo_file()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			file_manager.rename_todo_file(choice.path)
		end
	end)
end

--- 删除 TODO 文件.
function M.delete_todo_file()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			file_manager.delete_todo_file(choice.path)
		end
	end)
end

return M
