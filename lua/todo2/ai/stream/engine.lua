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
-- 调试模式
------------------------------------------------------------
local DEBUG = false

local function debug_log(task_id, message)
	if DEBUG then
		print(string.format("[Engine-%s] %s", task_id or "global", message))
	end
end

------------------------------------------------------------
-- 安全写入 buffer
------------------------------------------------------------
local function safe_set_lines(bufnr, start, finish, lines)
	if not bufnr or bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
		debug_log(nil, "Invalid buffer for writing")
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
-- 通知UI状态变更
------------------------------------------------------------
local function notify_state_change(task_id, reason)
	debug_log(task_id, "State change: " .. (reason or "unknown"))
	status_ui.request_update(task_id)
end

------------------------------------------------------------
-- 写入队列
------------------------------------------------------------
-- 在 engine.lua 的 process_queue 函数中
local function process_queue(task_id)
	local state = tasks[task_id]
	if not state or not state.active or state.finished then
		return
	end

	if state.writing then
		return
	end

	if #state.queue == 0 then
		if state.closing then
			vim.schedule(function()
				M.finish(task_id)
			end)
		end
		return
	end

	state.writing = true
	local task = table.remove(state.queue, 1)

	-- 更新当前行号（用于进度显示）
	if state.range then
		state.current_line = task.start_line
		notify_state_change(task_id, "writing")
	end

	-- 写入，带进度回调
	local ok, err = writer.write(
		state.write_mode,
		state.bufnr,
		{
			start_line = task.start_line,
			end_line = task.end_line,
		},
		task.lines,
		{
			on_progress = function(current)
				if state.range then
					state.current_line = task.start_line + current
					notify_state_change(task_id, "progress")
				end
			end,
		}
	)

	if not ok then
		state.writing = false
		M.abort(task_id, "写入失败: " .. tostring(err))
		return
	end

	-- 更新进度
	if state.range then
		state.current_line = task.end_line + 1
		notify_state_change(task_id, "write completed")
	end

	state.writing = false

	-- 继续处理队列
	if #state.queue > 0 and state.active and not state.finished then
		vim.schedule(function()
			process_queue(task_id)
		end)
	elseif #state.queue == 0 and state.closing then
		vim.schedule(function()
			M.finish(task_id)
		end)
	end
end

------------------------------------------------------------
-- start
------------------------------------------------------------
function M.start(opts)
	local ai = require("todo2.ai")
	if not ai.current_config then
		return false, nil, "当前没有可用模型:TodoAISelectModel"
	end

	local bufnr = vim.fn.bufnr(opts.path)
	if bufnr == -1 then
		return false, nil, "找不到 buffer: " .. opts.path
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
	state.model_full_name = ai.current_config.name or "AI"

	local task_id = tostring(vim.loop.now()) .. "_" .. math.random(1000, 9999)
	tasks[task_id] = state

	debug_log(task_id, "Task started")

	vim.schedule(function()
		status_ui.create(task_id, bufnr, state)
		notify_state_change(task_id, "initial")
	end)

	return true, task_id, nil
end

------------------------------------------------------------
-- on_chunk
------------------------------------------------------------
function M.on_chunk(task_id, chunk)
	local state = tasks[task_id]
	if not state then
		debug_log(task_id, "Chunk received but task not found")
		return
	end

	if state.closing or state.finished then
		debug_log(task_id, "Chunk ignored: closing/finished")
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
	debug_log(task_id, "Chunk received, buffer size: " .. #state.buffer)

	-- 第一阶段：协议解析前
	if not state.protocol then
		local p = protocol.parse(state.buffer)
		if p then
			state.protocol = p
			debug_log(task_id, "Protocol parsed")
			notify_state_change(task_id, "protocol parsed")

			-- 尝试定位
			local range, err = locator.locate(p, state.ctx)
			if range then
				state.range = range
				state.current_line = range.start_line
				debug_log(task_id, "Range located: " .. range.start_line .. "-" .. range.end_line)
				notify_state_change(task_id, "range located")
			else
				debug_log(task_id, "Range location failed: " .. tostring(err))
				-- 继续等待更多数据？还是立即失败？
				-- 这里选择等待，因为可能协议不完整
			end

			-- 处理缓冲区中的内容
			local body = state.buffer:match(":%s*\n(.*)")
			if body and body ~= "" then
				local lines = vim.split(body, "\n", { plain = true })
				debug_log(task_id, "Processing buffered content: " .. #lines .. " lines")
				table.insert(state.queue, {
					start_line = state.current_line,
					end_line = state.current_line + #lines - 1,
					lines = lines,
				})
				notify_state_change(task_id, "queued buffered content")
				vim.schedule(function()
					process_queue(task_id)
				end)
			end
		else
			debug_log(task_id, "Waiting for more data to parse protocol")
		end
		return
	end

	-- 第二阶段：协议已解析，处理新chunk
	if not state.range then
		-- 如果还没有定位成功，继续尝试
		local range, err = locator.locate(state.protocol, state.ctx)
		if range then
			state.range = range
			state.current_line = range.start_line
			debug_log(task_id, "Range located from later data")
			notify_state_change(task_id, "range located")
		else
			debug_log(task_id, "Still waiting for range location")
			return
		end
	end

	-- 处理chunk内容
	local lines = vim.split(chunk, "\n", { plain = true })
	if #lines > 0 then
		debug_log(task_id, "Queuing " .. #lines .. " lines")
		table.insert(state.queue, {
			start_line = state.current_line,
			end_line = state.current_line + #lines - 1,
			lines = lines,
		})
		notify_state_change(task_id, "content queued")

		-- 如果当前没有在写入，启动队列处理
		if not state.writing then
			vim.schedule(function()
				process_queue(task_id)
			end)
		end
	end
end

------------------------------------------------------------
-- finish
------------------------------------------------------------
function M.finish(task_id)
	local state = tasks[task_id]
	if not state then
		debug_log(task_id, "Finish called but task not found")
		status_ui.remove(task_id)
		return false, "任务不存在", nil
	end

	debug_log(task_id, "Finishing task")

	-- 如果还有队列内容或正在写入，标记为closing并等待
	if state.writing or #state.queue > 0 then
		if not state.closing then
			state.closing = true
			debug_log(task_id, "Task marked as closing, waiting for queue")
			notify_state_change(task_id, "closing")
			status_ui.stop_animation(task_id)
		end
		return true, nil, { async = true }
	end

	status_ui.stop_animation(task_id)

	if state.error_message then
		debug_log(task_id, "Task failed: " .. state.error_message)
		status_ui.remove(task_id)
		tasks[task_id] = nil
		return false, error_handler.format(state.error_message), nil
	end

	if not state.received_chunk then
		debug_log(task_id, "No output received")
		status_ui.remove(task_id)
		tasks[task_id] = nil
		return false, error_handler.format("no output"), nil
	end

	if not state.range then
		debug_log(task_id, "Range not located")
		status_ui.remove(task_id)
		tasks[task_id] = nil
		return false, error_handler.format("protocol or locator failed"), nil
	end

	state.finished = true
	state.active = false

	local final_start = state.range.start_line
	local final_end = (state.current_line or final_start) - 1

	debug_log(task_id, "Task finished successfully: " .. final_start .. "-" .. final_end)

	status_ui.remove(task_id)
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
		debug_log(task_id, "Wait finish: task not found")
		status_ui.remove(task_id)
		return false, "任务不存在", nil
	end

	debug_log(task_id, "Waiting for finish, timeout: " .. timeout_ms .. "ms")

	local start = vim.loop.now()
	while state.writing or #state.queue > 0 do
		if vim.loop.now() - start > timeout_ms then
			debug_log(task_id, "Wait finish timeout")
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
		debug_log(task_id, "Abort: task not found")
		status_ui.remove(task_id)
		return
	end

	debug_log(task_id, "Aborting task: " .. tostring(reason))

	state.error_message = reason or "unknown abort"
	state.finished = true
	state.active = false

	status_ui.stop_animation(task_id)
	notify_state_change(task_id, "aborted")

	-- 恢复原始内容
	vim.schedule(function()
		if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
			debug_log(task_id, "Restoring original content")
			safe_set_lines(state.bufnr, state.ctx.start_line - 1, state.ctx.end_line, state.original_backup)
		end
		status_ui.remove(task_id)
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
		debug_log(task_id, "Stop: task not found")
		status_ui.remove(task_id)
		return false, "任务不存在"
	end

	if not state.active then
		debug_log(task_id, "Stop: task not active")
		status_ui.remove(task_id)
		return false, "当前没有正在运行的 AI 任务"
	end

	debug_log(task_id, "User stopped task")
	M.abort(task_id, "用户主动终止")
	return true
end

------------------------------------------------------------
-- 获取任务状态（用于调试）
------------------------------------------------------------
function M.get_task_info(task_id)
	local state = tasks[task_id]
	if not state then
		return nil
	end

	return {
		active = state.active,
		finished = state.finished,
		closing = state.closing,
		writing = state.writing,
		queue_size = #state.queue,
		has_protocol = state.protocol ~= nil,
		has_range = state.range ~= nil,
		current_line = state.current_line,
		received_chunk = state.received_chunk,
		error = state.error_message,
	}
end

return M
