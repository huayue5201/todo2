-- lua/todo2/handlers/task.lua
-- 任务操作处理器：切换状态 / 循环 / 删除 / 编辑
-- 处理器返回 true 表示已处理；返回 false 表示未处理，由 keymaps 回退到默认键行为

local M = {}

local line = require("todo2.utils.line")
local core = require("todo2.store.task.core")
local state_manager = require("todo2.core.state_manager")
local deleter = require("todo2.task.deleter")
local format = require("todo2.utils.format")
local input_ui = require("todo2.ui.input")
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local buffer = require("todo2.utils.buffer")
local cursor = require("todo2.task.cursor")
local file = require("todo2.utils.file")
local id_utils = require("todo2.utils.id")

--- 切换任务状态（在 TODO 文件或代码文件中）
function M.toggle_task_status()
	local analysis = line.analyze_current_line()
	local info = buffer.get_current_info()

	-- TODO 文件中的任务行
	if analysis.id then
		state_manager.toggle_line(nil, nil, { id = analysis.id })
		return true
	end

	-- 代码文件中的任务
	if not info.is_todo_file then
		local task = cursor.get_task(info.bufnr, vim.fn.line("."))
		if task then
			state_manager.toggle_line(nil, nil, { id = task.id })
			return true
		end
	end

	return false
end

--- 循环切换任务状态
function M.cycle_status()
	local analysis = line.analyze_current_line()
	local info = buffer.get_current_info()
	local id = nil

	if info.is_todo_file and analysis.id then
		id = analysis.id
	elseif not info.is_todo_file then
		local task = cursor.get_task(info.bufnr, vim.fn.line("."))
		if task then
			id = task.id
		end
	end

	if not id then
		return false
	end

	local core_status = require("todo2.core.status")
	local task = core.get_task(id)
	if not task then
		return false
	end

	core_status.cycle(id)
	return true
end

--- 智能删除：删除任务或删除任务行（支持可视模式）
function M.smart_delete()
	local info = buffer.get_current_info()
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

		local first_line = vim.api.nvim_buf_get_lines(info.bufnr, start_lnum - 1, start_lnum, false)[1]
		-- 普通任务（无 ID）直接删除行
		if first_line and first_line:match("^%s*- %[[^]]%]") and not id_utils.contains_mark(first_line) then
			vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, end_lnum, false, {})
			autosave.request_save(info.bufnr)
			return true
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

		return true
	else
		-- 代码文件：删除任务（不删除代码行）
		local task = cursor.get_task(info.bufnr, vim.fn.line("."))
		if task then
			local success, _ = deleter.delete_by_ids({ task.id })
			if not success then
				vim.notify("删除任务失败", vim.log.levels.WARN)
			end
			return true
		end
		return false
	end
end

--- 从代码文件编辑关联的 TODO 任务内容
function M.edit_task_from_code()
	local info = buffer.get_current_info()
	local task = cursor.get_task(info.bufnr, vim.fn.line("."))

	if not task or not task.locations.todo then
		return false
	end

	local id = task.id
	local path = task.locations.todo.path
	local line_num = task.locations.todo.line

	local lines = file.read_lines_smart(path)
	if not lines or #lines == 0 or line_num < 1 or line_num > #lines then
		vim.notify("无法读取 TODO 文件或行号无效", vim.log.levels.ERROR)
		return true
	end

	local old_line = lines[line_num]
	local parsed = format.parse_task_line(old_line)
	if not parsed then
		vim.notify("当前行不是有效的任务行", vim.log.levels.ERROR)
		return true
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

		task.core.content = new_content
		task.core.content_hash = require("todo2.utils.hash").hash(new_content)
		task.timestamps.updated = os.time()
		core.save_task(id, task)

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

		events.emit("edit_task_from_code", {
			file = path,
			changed_ids = { id },
		})
	end)

	return true
end

return M
