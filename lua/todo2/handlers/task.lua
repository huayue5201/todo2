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

---@param cmd_args? table 用户命令参数（带 line1/line2 时以它为准，即 `:TodoDel` 的范围）
---删除被拒绝时给出可操作的下一步，而不是干巴巴一句 "Delete failed"
---@param res table|nil deleter.delete_by_ids 的结果
local function notify_delete_refused(res)
	local has_children = false
	for _, d in ipairs((res and res.details) or {}) do
		if d.error == "has_children" then
			has_children = true
			break
		end
	end
	if has_children then
		vim.notify(
			"todo2: task has child tasks — `:TodoDel!` deletes it with the whole subtree, "
				.. "`:TodoTask promote` deletes only it and lifts the children",
			vim.log.levels.WARN
		)
	else
		vim.notify("Delete failed", vim.log.levels.WARN)
	end
end

---选中的多行里只保留「最外层」的任务 id：文件里父任务一定排在子任务前面，
---所以第一个出现的最小缩进就是本段的根；子任务交给 cascade 一并删除。
---否则按 forbid 逐个删，父任务会因 has_children 失败，只删掉子树的一部分。
---@param analysis { analyses: LineAnalysis[] }
---@return string[]
local function top_level_ids(analysis)
	local keep, min_indent = {}, nil
	for _, a in ipairs(analysis.analyses or {}) do
		if a.is_mark and a.id then
			local indent = #(a.line:match("^%s*") or "")
			if not min_indent or indent <= min_indent then
				min_indent = indent
				table.insert(keep, a.id)
			end
		end
	end
	return keep
end

---范围删除时把选中范围内「没有 id 的手写任务行」也删掉（不动选中范围之外的正文块）。
---必须从后往前删，否则行号会漂移。
---@return number deleted 删除的行数
local function delete_plain_task_lines(bufnr, start_lnum, end_lnum)
	local total = vim.api.nvim_buf_line_count(bufnr)
	end_lnum = math.min(end_lnum, total)
	local targets = {}
	for lnum = start_lnum, end_lnum do
		local text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
		if format.is_task_line(text) then
			local parsed = format.parse_task_line(text)
			if parsed and not parsed.id then
				table.insert(targets, lnum)
			end
		end
	end
	for i = #targets, 1, -1 do
		vim.api.nvim_buf_set_lines(bufnr, targets[i] - 1, targets[i], false, {})
	end
	if #targets > 0 then
		autosave.request_save(bufnr)
	end
	return #targets
end

function M.smart_delete(cmd_args)
	local info = buffer.get_current_info()
	local mode = vim.fn.mode()

	if info.is_todo_file then
		local start_lnum, end_lnum
		local l1 = cmd_args and tonumber(cmd_args.line1)
		local l2 = cmd_args and tonumber(cmd_args.line2)
		if l1 and l2 then
			-- `:TodoDel` 支持范围：不带范围时 line1 == line2 == 当前行，
			-- 可视模式下用 `:'<,'>TodoDel` 即可（不再依赖 mode() 判断）
			start_lnum, end_lnum = math.min(l1, l2), math.max(l1, l2)
		elseif mode == "v" or mode == "V" then
			start_lnum = vim.fn.line("v")
			end_lnum = vim.fn.line(".")
			if start_lnum > end_lnum then
				start_lnum, end_lnum = end_lnum, start_lnum
			end
		else
			start_lnum = vim.fn.line(".")
			end_lnum = start_lnum
		end

		-- 范围可能超出缓冲区（例如带范围调用时文件已变短）
		local total = vim.api.nvim_buf_line_count(info.bufnr)
		start_lnum = math.max(1, math.min(start_lnum, total))
		end_lnum = math.max(start_lnum, math.min(end_lnum, total))

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
			-- 多行范围 = 一次批量删除：取最外层任务 + cascade（连同子树），
			-- 单行默认 forbid（有子任务时明确拒绝，避免误删整棵子树），
			-- `:TodoDel!` 显式要求连子树一起删。
			-- 一条策略：默认只删自身（有子任务就拒绝并说明下一步）；
			-- `!` 或可视范围 = 显式表示"连子树一起删"，并回报实际删了多少。
			local multi = start_lnum ~= end_lnum
			local force = cmd_args ~= nil and cmd_args.bang == true
			local cascade = multi or force
			local ids = multi and top_level_ids(analysis) or analysis.ids
			local success, res = deleter.delete_by_ids(ids, cascade and { mode = "cascade" } or nil)
			if not success then
				notify_delete_refused(res)
			elseif cascade and res and (res.succeeded or 0) > 1 then
				vim.notify(
					("todo2: deleted %d tasks (subtree included)"):format(res.succeeded),
					vim.log.levels.INFO
				)
			end
			if multi then
				delete_plain_task_lines(info.bufnr, start_lnum, end_lnum)
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
			-- 代码侧同样尊重 `!`：不带 bang 时有子任务就拒绝，而不是提示一个用不了的 `!`
			local force = cmd_args ~= nil and cmd_args.bang == true
			local success, res = deleter.delete_by_ids({ task.id }, force and { mode = "cascade" } or nil)
			if not success then
				notify_delete_refused(res)
			end
		end)
	end
end

--- 只删任务自身，子任务提升一级（`:TodoTask promote`）
---@return boolean
local function promote_by_id(id)
	local ok, res = deleter.delete_promote(id)
	if not ok then
		vim.notify("Promote failed: " .. tostring(res and (res.error or res.reason) or "unknown"), vim.log.levels.WARN)
		return false
	end
	return true
end

function M.promote_current()
	local info = buffer.get_current_info()

	if info.is_todo_file then
		local analysis = line.analyze_line(info.bufnr, vim.fn.line("."))
		if analysis and analysis.is_todo_task and not analysis.id then
			vim.notify("todo2: this line has no task id — just delete the line", vim.log.levels.WARN)
			return false
		end
		if not (analysis and analysis.id) then
			vim.notify("No task on the current line", vim.log.levels.WARN)
			return false
		end
		return promote_by_id(analysis.id)
	end

	-- 代码文件：在该行关联的任务里选一个，只删任务、不动代码
	return picker.pick({ bufnr = info.bufnr, none_msg = false }, function(task)
		promote_by_id(task.id)
	end)
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
		core.touch(task, "content")
		core.save_task(id, task)

		local new_line = format.task_line(task, {
			indent = parsed.indent,
			checkbox = parsed.checkbox,
			id = parsed.id,
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
