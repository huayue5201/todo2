-- lua/todo2/ai/stream/engine.lua
local protocol = require("todo2.ai.stream.protocol")
local locator = require("todo2.ai.stream.locator")
local writer = require("todo2.ai.stream.writer")
local status_ui = require("todo2.ai.stream.status_ui")
local error_handler = require("todo2.ai.stream.error_handler")
local State = require("todo2.ai.stream.state")
local normalizer = require("todo2.ai.stream.normalizer")

local M = {}
local tasks = {} -- key = task_id, value = state

------------------------------------------------------------
-- 安全写入 buffer
------------------------------------------------------------
local function safe_set_lines(bufnr, start, finish, lines)
	if not bufnr or bufnr == -1 then
		return
	end
	if start > finish then
		finish = start
	end
	lines = lines or {}
	pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, start, finish, false, lines)
	end)
end

------------------------------------------------------------
-- 写入队列
------------------------------------------------------------
local function process_queue(task_id)
	local state = tasks[task_id]
	if not state or not state.active or state.finished then
		return
	end
	if #state.queue == 0 then
		return
	end

	state.writing = true
	local task = table.remove(state.queue, 1)

	writer.write(state.write_mode, state.bufnr, {
		start_line = task.start_line,
		end_line = task.end_line,
	}, task.lines)

	pcall(function()
		vim.cmd("silent! undojoin")
	end)

	state.current_line = task.end_line + 1
	status_ui.update(task_id)

	state.writing = false

	if #state.queue > 0 and state.active then
		vim.schedule(function()
			process_queue(task_id)
		end)
	end
end

------------------------------------------------------------
-- start
------------------------------------------------------------
function M.start(opts)
	local ai = require("todo2.ai")
	if not ai.current_config then
		return false, nil, "当前没有可用模型:TodoAISelectModel" -- 返回 false, nil, error
	end

	local bufnr = vim.fn.bufnr(opts.path)
	if bufnr == -1 then
		return false, nil, "找不到 buffer: " .. opts.path -- 返回 false, nil, error
	end

	local original = vim.api.nvim_buf_get_lines(bufnr, opts.ctx.start_line - 1, opts.ctx.end_line, false)
	local state = State.new()

	state.active = true
	state.finished = false
	state.closing = false
	state.bufnr = bufnr
	state.path = opts.path
	state.todo = opts.todo
	state.ctx = opts.ctx
	state.code_link = opts.code_link
	state.protocol = nil
	state.range = nil
	state.write_mode = "overwrite"
	state.original_backup = vim.deepcopy(original)
	state.buffer = ""
	state.queue = {}
	state.writing = false
	state.current_line = nil
	state.received_chunk = false
	state.error_message = nil
	state.marker_line = opts.code_link.line
	state.start_time = vim.loop.now() / 1000

	local task_id = tostring(vim.loop.now()) .. "_" .. math.random(1000, 9999)
	tasks[task_id] = state

	vim.schedule(function()
		status_ui.create(task_id, bufnr, state)
		status_ui.update(task_id)
	end)

	return true, task_id, nil -- ⭐ 统一返回：成功时第三个参数为 nil
end

------------------------------------------------------------
-- on_chunk
------------------------------------------------------------
function M.on_chunk(task_id, chunk)
	local state = tasks[task_id]
	if not state or state.closing or state.finished then
		return
	end
	if not chunk or chunk == "" then
		return
	end

	chunk = normalizer.normalize(chunk)
	if chunk == "" then
		return
	end

	state.received_chunk = true
	state.buffer = state.buffer .. chunk

	if not state.protocol then
		local p = protocol.parse(state.buffer)
		if not p then
			return
		end
		state.protocol = p
		local range, err = locator.locate(p, state.ctx)
		if not range then
			M.abort(task_id, "定位失败: " .. tostring(err))
			return
		end
		state.range = range
		state.current_line = range.start_line
		status_ui.update(task_id)

		local body = state.buffer:match(":%s*\n(.*)")
		if body and body ~= "" then
			local lines = vim.split(body, "\n", { plain = true })
			table.insert(state.queue, {
				start_line = state.current_line,
				end_line = state.current_line + #lines - 1,
				lines = lines,
			})
			vim.schedule(function()
				process_queue(task_id)
			end)
		end
		return
	end

	local lines = vim.split(chunk, "\n", { plain = true })
	if #lines > 0 then
		table.insert(state.queue, {
			start_line = state.current_line,
			end_line = state.current_line + #lines - 1,
			lines = lines,
		})
		vim.schedule(function()
			process_queue(task_id)
		end)
	end
end

------------------------------------------------------------
-- finish
------------------------------------------------------------
function M.finish(task_id)
	local state = tasks[task_id]
	if not state then
		status_ui.remove(task_id)
		return false, "任务不存在", nil
	end

	status_ui.stop_animation(task_id)
	status_ui.remove(task_id)

	if state.error_message then
		tasks[task_id] = nil
		return false, error_handler.format(state.error_message), nil
	end

	if not state.received_chunk then
		tasks[task_id] = nil
		return false, error_handler.format("no output"), nil
	end

	if not state.range then
		tasks[task_id] = nil
		return false, error_handler.format("protocol or locator failed"), nil
	end

	if state.writing or #state.queue > 0 then
		state.closing = true
		return true, nil, { async = true }
	end

	state.finished = true
	state.active = false

	local final_start = state.range.start_line
	local final_end = (state.current_line or final_start) - 1
	tasks[task_id] = nil

	return true, nil, { start_line = final_start, end_line = final_end }
end

------------------------------------------------------------
-- wait_finish
------------------------------------------------------------
function M.wait_finish(task_id, timeout_ms)
	timeout_ms = timeout_ms or 5000
	local state = tasks[task_id]
	if not state then
		status_ui.remove(task_id)
		return false, "任务不存在", nil
	end

	local start = vim.loop.now()
	while state.writing or #state.queue > 0 do
		if vim.loop.now() - start > timeout_ms then
			return false, "等待写入超时", nil
		end
		vim.wait(10)
	end

	return M.finish(task_id)
end

------------------------------------------------------------
-- abort
------------------------------------------------------------
function M.abort(task_id, reason)
	local state = tasks[task_id]
	if not state then
		status_ui.remove(task_id)
		return
	end

	state.error_message = reason or "unknown abort"
	state.finished = true
	state.active = false

	status_ui.stop_animation(task_id)
	status_ui.remove(task_id)

	vim.schedule(function()
		safe_set_lines(state.bufnr, state.ctx.start_line - 1, state.ctx.end_line, state.original_backup)
	end)

	tasks[task_id] = nil
	vim.notify("AI 流式任务已中断: " .. tostring(reason), vim.log.levels.WARN)
end

------------------------------------------------------------
-- stop
------------------------------------------------------------
function M.stop(task_id)
	local state = tasks[task_id]

	if not state then
		status_ui.remove(task_id)
		return false, "任务不存在"
	end

	if not state.active then
		status_ui.remove(task_id)
		return false, "当前没有正在运行的 AI 任务"
	end

	M.abort(task_id, "用户主动终止")
	return true
end

return M
