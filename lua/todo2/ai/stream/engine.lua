-- lua/todo2/ai/stream/engine.lua
-- 流式执行引擎：协议解析 + 定位 + 写入（策略化）

local protocol = require("todo2.ai.stream.protocol")
local locator = require("todo2.ai.stream.locator")
local writer = require("todo2.ai.stream.writer")
local status_ui = require("todo2.ai.stream.status_ui")
local State = require("todo2.ai.stream.state")

local M = {}

local state = State.new()

------------------------------------------------------------
-- 写入队列
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

local function process_queue()
	if state.writing or state.finished or not state.active then
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
	state.writing = false

	-- ⭐ 写入后更新 UI
	status_ui.update(state.bufnr, state)

	if #state.queue > 0 and not state.finished then
		vim.schedule(process_queue)
	end
end

------------------------------------------------------------
-- start
------------------------------------------------------------
function M.start(opts)
	if state.active then
		return false, "已有流式任务正在执行"
	end

	local bufnr = vim.fn.bufnr(opts.path)
	if bufnr == -1 then
		return false, "找不到 buffer: " .. opts.path
	end

	local original = vim.api.nvim_buf_get_lines(bufnr, opts.ctx.start_line - 1, opts.ctx.end_line, false)

	state.active = true
	state.closing = false
	state.finished = false
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
	state.start_time = vim.loop.now() / 1000 -- ⭐ ETA 需要

	-- ⭐ 启动 UI 动画
	vim.schedule(function()
		status_ui.start_animation(bufnr, state)
		status_ui.update(bufnr, state)
	end)

	return true
end

------------------------------------------------------------
-- on_chunk
------------------------------------------------------------
function M.on_chunk(chunk)
	if not state.active or state.closing or state.finished then
		return
	end
	if not chunk or chunk == "" then
		return
	end

	state.buffer = state.buffer .. chunk

	-- 1. 解析协议
	if not state.protocol then
		local p = protocol.parse(state.buffer)
		if not p then
			return
		end
		state.protocol = p

		-- 2. 定位范围
		local range, err = locator.locate(p, state.ctx)
		if not range then
			M.abort("定位失败: " .. tostring(err))
			return
		end
		state.range = range
		state.current_line = range.start_line

		-- ⭐ 更新 UI
		status_ui.update(state.bufnr, state)

		-- 3. 去掉头部，处理剩余内容
		local body = state.buffer:match(":%s*\n(.*)")
		if body and body ~= "" then
			local lines = vim.split(body, "\n", { plain = true })
			table.insert(state.queue, {
				start_line = state.current_line,
				end_line = state.current_line + #lines - 1,
				lines = lines,
			})
			vim.schedule(process_queue)
		end
		return
	end

	-- 已有协议，直接把 chunk 当作代码写入
	local lines = vim.split(chunk, "\n", { plain = true })
	if #lines == 0 then
		return
	end

	table.insert(state.queue, {
		start_line = state.current_line,
		end_line = state.current_line + #lines - 1,
		lines = lines,
	})
	vim.schedule(process_queue)
end

------------------------------------------------------------
-- finish
------------------------------------------------------------
function M.finish()
	if not state.active then
		return false, "没有正在执行的流式任务", nil
	end
	if state.finished then
		return true,
			nil,
			{
				start_line = state.range and state.range.start_line or state.ctx.start_line,
				end_line = (state.current_line or (state.range and state.range.end_line or state.ctx.end_line)) - 1,
			}
	end

	state.closing = true

	-- ⭐ 停止动画
	status_ui.stop_animation()

	-- ⭐ 清除 UI 行
	status_ui.clear(state.bufnr, state)

	local function do_finish()
		if state.finished then
			return true,
				nil,
				{
					start_line = state.range and state.range.start_line or state.ctx.start_line,
					end_line = (state.current_line or (state.range and state.range.end_line or state.ctx.end_line)) - 1,
				}
		end

		if state.writing or #state.queue > 0 then
			vim.defer_fn(do_finish, 10)
			return
		end

		state.finished = true
		state.closing = false
		state.active = false

		local final_start = state.range and state.range.start_line or state.ctx.start_line
		local final_end = state.range and state.range.end_line or state.ctx.end_line

		if state.current_line and state.current_line - 1 < final_end then
			safe_set_lines(state.bufnr, state.current_line - 1, final_end, {})
		end

		return true, nil, {
			start_line = final_start,
			end_line = (state.current_line or final_start) - 1,
		}
	end

	vim.defer_fn(do_finish, 10)
	return true, nil, nil
end

------------------------------------------------------------
-- abort
------------------------------------------------------------
function M.abort(reason)
	if not state.active or state.finished then
		return
	end

	state.closing = true
	state.finished = true

	-- ⭐ 停止动画
	status_ui.stop_animation()

	-- ⭐ 清除 UI 行
	status_ui.clear(state.bufnr, state)

	vim.schedule(function()
		local start_idx = state.ctx.start_line - 1
		local end_idx = state.ctx.end_line
		safe_set_lines(state.bufnr, start_idx, end_idx, state.original_backup)

		state.active = false
		state.closing = false
	end)

	if reason then
		vim.notify("AI 流式任务已中断: " .. tostring(reason), vim.log.levels.WARN)
	end
end

------------------------------------------------------------
-- 状态查询
------------------------------------------------------------
function M.get_status()
	return status_ui.render(state)
end

function M.is_running()
	return state.active and not state.finished
end

return M
