-- lua/todo2/ai/stream/engine.lua
-- 流式引擎：使用协议状态机处理分片数据

local protocol = require("todo2.ai.stream.protocol")
local locator = require("todo2.ai.stream.locator")
local writer = require("todo2.ai.stream.writer")
local status_ui = require("todo2.ai.stream.status_ui")
local error_handler = require("todo2.ai.stream.error_handler")
local normalizer = require("todo2.ai.stream.normalizer")
local State = require("todo2.ai.stream.state")

local M = {}
local tasks = {}

local DEBUG = true

local function debug_log(task_id, message)
	if DEBUG then
		print(string.format("[Engine-%s] %s", task_id or "global", message))
	end
end

---处理写入队列
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

	if state.range then
		state.current_line = task.start_line
		status_ui.request_update(task_id)
	end

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
					status_ui.request_update(task_id)
				end
			end,
		}
	)

	if not ok then
		state.writing = false
		M.abort(task_id, "写入失败: " .. tostring(err))
		return
	end

	if state.range then
		state.current_line = task.end_line + 1
		status_ui.request_update(task_id)
	end

	state.writing = false

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

---启动流式任务
function M.start(opts)
	local ai = require("todo2.ai")
	if not ai.current_config then
		return false, nil, "当前没有可用模型，请执行 :TodoAISelectModel"
	end

	local bufnr = vim.fn.bufnr(opts.path)
	if bufnr == -1 then
		-- 文件未打开，先打开
		vim.cmd("edit " .. vim.fn.fnameescape(opts.path))
		bufnr = vim.fn.bufnr(opts.path)
		if bufnr == -1 then
			return false, nil, "无法打开文件: " .. opts.path
		end
	end
	vim.fn.bufload(bufnr)

	local original = vim.api.nvim_buf_get_lines(bufnr, opts.ctx.start_line - 1, opts.ctx.end_line, false)
	local state = State.new()
	State.reset(state, opts, original)

	state.bufnr = bufnr
	state.model_full_name = ai.current_config.display_name or ai.current_config.name or "AI"

	-- 创建协议解析器
	state.parser = protocol.new()

	local task_id = tostring(vim.loop.hrtime()) .. "_" .. math.random(1000, 9999)
	tasks[task_id] = state

	debug_log(
		task_id,
		"Task started, buffer: " .. bufnr .. ", lines: " .. state.ctx.start_line .. "-" .. state.ctx.end_line
	)

	vim.schedule(function()
		status_ui.create(task_id, bufnr, state)
		status_ui.request_update(task_id)
	end)

	return true, task_id, nil
end

---处理流式数据块
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

	-- 规范化
	chunk = normalizer.normalize(chunk)
	if chunk == "" then
		return
	end

	state.received_chunk = true

	-- 喂给协议解析器
	local result = protocol.feed(state.parser, chunk)

	-- 如果协议解析完成
	if result and not state.protocol then
		state.protocol = result
		debug_log(
			task_id,
			string.format(
				"Protocol parsed: start=%d, end=%d, hash=%s",
				result.start_line or 0,
				result.end_line or 0,
				result.signature_hash or "none"
			)
		)

		-- 定位代码范围
		local range, err = locator.locate(result, state.ctx)
		if range then
			state.range = range
			state.current_line = range.start_line
			debug_log(task_id, "Range located: " .. range.start_line .. "-" .. range.end_line)
			status_ui.request_update(task_id)
		else
			debug_log(task_id, "Range location failed: " .. tostring(err))
		end
	end

	-- 如果协议解析完成且有代码
	if state.protocol and state.range and state.parser.result and state.parser.result.code then
		local code = state.parser.result.code
		if code and code ~= "" then
			-- 清理代码（移除可能的多余空行）
			code = code:gsub("^\n+", ""):gsub("\n+$", "")
			local lines = vim.split(code, "\n", { plain = true })

			debug_log(task_id, string.format("Extracted %d lines of code", #lines))

			if #lines > 0 then
				table.insert(state.queue, {
					start_line = state.range.start_line,
					end_line = state.range.start_line + #lines - 1,
					lines = lines,
				})
				state.current_line = state.range.start_line + #lines
				status_ui.request_update(task_id)

				if not state.writing then
					vim.schedule(function()
						process_queue(task_id)
					end)
				end
			end
		end
	end
end

---完成任务
function M.finish(task_id)
	local state = tasks[task_id]
	if not state then
		debug_log(task_id, "Finish called but task not found")
		status_ui.remove(task_id)
		return false, "任务不存在", nil
	end

	debug_log(task_id, "Finishing task")

	if state.writing or #state.queue > 0 then
		if not state.closing then
			state.closing = true
			debug_log(task_id, "Task marked as closing, waiting for queue")
			status_ui.request_update(task_id)
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

	if final_end < final_start then
		final_end = final_start - 1
	end

	debug_log(task_id, "Task finished successfully: " .. final_start .. "-" .. final_end)

	status_ui.remove(task_id)
	tasks[task_id] = nil

	return true, nil, { start_line = final_start, end_line = final_end }
end

---等待任务完成
function M.wait_finish(task_id, timeout_ms)
	timeout_ms = timeout_ms or 5000
	local state = tasks[task_id]
	if not state then
		return false, "任务不存在", nil
	end

	local start = vim.loop.hrtime() / 1e6
	while state.writing or #state.queue > 0 do
		if (vim.loop.hrtime() / 1e6) - start > timeout_ms then
			return false, "等待写入超时", nil
		end
		vim.wait(10)
	end

	return M.finish(task_id)
end

---中止任务
function M.abort(task_id, reason)
	local state = tasks[task_id]
	if not state then
		status_ui.remove(task_id)
		return
	end

	debug_log(task_id, "Aborting task: " .. tostring(reason))

	state.error_message = reason or "unknown abort"
	state.finished = true
	state.active = false

	status_ui.stop_animation(task_id)
	status_ui.request_update(task_id)

	-- 恢复原始内容
	vim.schedule(function()
		if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
			local lines = vim.api.nvim_buf_get_lines(state.bufnr, state.ctx.start_line - 1, state.ctx.end_line, false)
			if #lines ~= #state.original_backup then
				vim.api.nvim_buf_set_lines(
					state.bufnr,
					state.ctx.start_line - 1,
					state.ctx.end_line,
					false,
					state.original_backup
				)
			end
		end
		status_ui.remove(task_id)
	end)

	tasks[task_id] = nil
	vim.notify("AI 流式任务已中断: " .. tostring(reason), vim.log.levels.WARN)
end

---停止任务
function M.stop(task_id)
	local state = tasks[task_id]

	if not state then
		return false, "任务不存在"
	end

	if not state.active then
		return false, "当前没有正在运行的 AI 任务"
	end

	M.abort(task_id, "用户主动终止")
	return true, nil
end

---获取任务信息
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
