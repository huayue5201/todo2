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
local description = require("todo2.core.description")
local picker = require("todo2.task.picker")
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
		return picker.pick({ bufnr = info.bufnr, none_msg = false }, function(task)
			state_manager.toggle_line(nil, nil, { id = task.id })
		end)
	end

	return false
end

--- 循环切换任务状态
function M.cycle_status()
	local analysis = line.analyze_current_line()
	local info = buffer.get_current_info()
	local core_status = require("todo2.core.status")

	if info.is_todo_file and analysis.id then
		core_status.cycle(analysis.id)
		return true
	end

	if not info.is_todo_file then
		return picker.pick({ bufnr = info.bufnr, none_msg = false }, function(task)
			core_status.cycle(task.id)
		end)
	end

	return false
end

--- 智能删除：删除任务或删除任务行（支持可视模式）
--- 单行直删时，把该任务行的正文块一并算进去（正文与任务强绑定）。
--- 可视化选中的多行范围不扩展，尊重用户选择。
---@param bufnr number
---@param start_lnum number
---@param end_lnum number
---@return number
local function delete_end_lnum(bufnr, start_lnum, end_lnum)
	if start_lnum ~= end_lnum then
		return end_lnum
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local block = description.block_at(lines, start_lnum)
	return block and block.end_line or end_lnum
end

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
		-- 普通任务（无 ID）直接删除行（连同正文块）
		if first_line and first_line:match("^%s*- %[[^]]%]") and not id_utils.contains_mark(first_line) then
			local stop = delete_end_lnum(info.bufnr, start_lnum, end_lnum)
			vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, stop, false, {})
			autosave.request_save(info.bufnr)
			return true
		end

		local analysis = line.analyze_lines(info.bufnr, start_lnum, end_lnum)

		if #analysis.ids > 0 then
			local success, _ = deleter.delete_by_ids(analysis.ids)
			if not success then
				vim.notify("Delete failed", vim.log.levels.WARN)
			end
		else
			local stop = delete_end_lnum(info.bufnr, start_lnum, end_lnum)
			vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, stop, false, {})
			autosave.request_save(info.bufnr)
		end

		return true
	else
		-- 代码文件：删除任务（不删除代码行）
		return picker.pick({ bufnr = info.bufnr, none_msg = false }, function(task)
			local success, _ = deleter.delete_by_ids({ task.id })
			if not success then
				vim.notify("Failed to delete task", vim.log.levels.WARN)
			end
		end)
	end
end

--- 按任务 ID 编辑任务内容（抽屉 / 代码文件通用）
---@param id string 任务 ID
---@return boolean
function M.edit_task_by_id(id)
	if not id then
		return false
	end
	local task = core.get_task(id)
	if not task or not task.locations.todo then
		vim.notify("Task or TODO location not found", vim.log.levels.ERROR)
		return false
	end

	local path = task.locations.todo.path
	local line_num = task.locations.todo.line

	local lines = file.read_lines_smart(path)
	if not lines or #lines == 0 or line_num < 1 or line_num > #lines then
		vim.notify("Cannot read TODO file or invalid line number", vim.log.levels.ERROR)
		return true
	end

	local old_line = lines[line_num]
	local parsed = format.parse_task_line(old_line)
	if not parsed then
		vim.notify("Current line is not a valid task line", vim.log.levels.ERROR)
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
		task.timestamps.updated = os.time()
		core.save_task(id, task)

		local new_line = format.format_task_line({
			indent = parsed.indent,
			checkbox = parsed.checkbox,
			id = parsed.id,
			status = task.core.status,
			tags = parsed.tags,
			content = new_content,
		})
		lines[line_num] = new_line

		local write_ok, write_err = pcall(vim.fn.writefile, lines, path)
		if not write_ok then
			vim.notify("Failed to write TODO file: " .. tostring(write_err), vim.log.levels.ERROR)
			return
		end

		events.emit("edit_task_from_code", {
			file = path,
			changed_ids = { id },
		})
	end)

	return true
end

--- 从代码文件编辑关联的 TODO 任务内容
function M.edit_task_from_code()
	local info = buffer.get_current_info()
	return picker.pick({ bufnr = info.bufnr, none_msg = false }, function(task)
		M.edit_task_by_id(task.id)
	end)
end

return M
