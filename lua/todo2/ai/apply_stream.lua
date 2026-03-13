-- lua/todo2/ai/apply_stream.lua
-- 修复版：防止重复写入、finish 无限等待、状态机冲突

local M = {}

---------------------------------------------------------------------
-- 内部状态机
---------------------------------------------------------------------
local state = {
	active = false,
	closing = false,
	finished = false,
	bufnr = nil,
	path = nil,
	todo = nil,
	ctx = nil,
	code_link = nil,
	start_line = nil,
	end_line = nil,
	original_lines = {},
	chunks = {},
	queue = {},
	writing = false,

	-- REPLACE 解析相关
	replace_parsed = false,
	replace_start = nil,
	replace_end = nil,
	header_removed = false,
	current_line = nil,
	header_buffer = "",
}

---------------------------------------------------------------------
-- 安全写入
---------------------------------------------------------------------
local function safe_set_lines(bufnr, start, finish, lines)
	if not bufnr or bufnr == -1 then
		return
	end

	if start > finish then
		finish = start
	end

	pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, start, finish, false, lines)
	end)
end

---------------------------------------------------------------------
-- 单线程写入队列处理器（修复 closing 阻塞队列）
---------------------------------------------------------------------
local function process_queue()
	if state.writing then
		return
	end
	if #state.queue == 0 then
		return
	end

	-- ❗ 修复点 1：closing 不再阻止队列继续写
	if state.finished then
		state.queue = {}
		return
	end

	state.writing = true

	local task = table.remove(state.queue, 1)

	if task.start > task.finish then
		task.finish = task.start
	end

	safe_set_lines(task.bufnr, task.start, task.finish, task.lines)

	if state.current_line then
		state.current_line = state.current_line + #task.lines
	end

	pcall(function()
		vim.cmd("silent! undojoin")
	end)

	state.writing = false

	-- ❗ 修复点 2：closing 不再阻止继续消费队列
	if #state.queue > 0 and not state.finished then
		vim.schedule(process_queue)
	end
end

---------------------------------------------------------------------
-- 解析REPLACE指令
---------------------------------------------------------------------
local function parse_replace_header(text)
	local compact = text:gsub("%s+", "")
	local start_line, end_line = compact:match("REPLACE(%d+)%-(%d+):?")
	if start_line then
		return tonumber(start_line), tonumber(end_line)
	end
	return nil, nil
end

---------------------------------------------------------------------
-- 1. start(): 初始化流式写入
---------------------------------------------------------------------
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
	state.start_line = opts.ctx.start_line
	state.end_line = opts.ctx.end_line
	state.original_lines = original
	state.chunks = {}
	state.queue = {}
	state.writing = false

	state.replace_parsed = false
	state.replace_start = nil
	state.replace_end = nil
	state.header_removed = false
	state.current_line = nil
	state.header_buffer = ""

	-- 清空原有代码区域
	vim.schedule(function()
		if state.finished then
			return
		end

		local start_idx = state.start_line - 1
		local end_idx = state.end_line
		if start_idx > end_idx then
			end_idx = start_idx
		end

		safe_set_lines(bufnr, start_idx, end_idx, {})
		pcall(function()
			vim.cmd("silent! undojoin")
		end)
	end)

	return true
end

---------------------------------------------------------------------
-- 2. on_chunk(): 接收 AI 的流式输出（防止重复）
---------------------------------------------------------------------
function M.on_chunk(chunk)
	if not state.active or state.closing or state.finished then
		return
	end
	if not chunk or chunk == "" then
		return
	end

	table.insert(state.chunks, chunk)

	-- 解析 REPLACE 头
	if not state.replace_parsed then
		state.header_buffer = state.header_buffer .. chunk

		local start_line, end_line = parse_replace_header(state.header_buffer)
		if start_line then
			state.replace_parsed = true
			state.replace_start = start_line
			state.replace_end = end_line
			state.current_line = start_line

			local replace_pos = state.header_buffer:find("REPLACE")
			if replace_pos then
				local colon_pos = state.header_buffer:find(":", replace_pos)
				if colon_pos then
					local content_start = state.header_buffer:find("\n", colon_pos)
					if content_start then
						local remaining = state.header_buffer:sub(content_start + 1)
						if remaining and remaining ~= "" then
							local lines = vim.split(remaining, "\n", { plain = true })
							if #lines > 0 then
								local unique_lines = {}
								local last_line = ""
								for _, line in ipairs(lines) do
									if line ~= last_line then
										table.insert(unique_lines, line)
										last_line = line
									end
								end

								table.insert(state.queue, {
									bufnr = state.bufnr,
									start = state.current_line - 1,
									finish = state.current_line - 1,
									lines = unique_lines,
								})
								vim.schedule(process_queue)
								state.current_line = state.current_line + #unique_lines
							end
						end
					end
				end
			end
			return
		end
		return
	end

	-- 正常 chunk
	if not state.current_line then
		state.current_line = state.replace_start or state.start_line
	end

	local lines = vim.split(chunk, "\n", { plain = true })
	if #lines == 0 then
		return
	end

	local last_task = state.queue[#state.queue]
	if last_task and #last_task.lines > 0 then
		local last_line = last_task.lines[#last_task.lines]
		if lines[1] == last_line then
			table.remove(lines, 1)
		end
	end

	if #lines > 0 then
		table.insert(state.queue, {
			bufnr = state.bufnr,
			start = state.current_line - 1,
			finish = state.current_line - 1,
			lines = lines,
		})
		vim.schedule(process_queue)
	end
end

---------------------------------------------------------------------
-- 3. finish(): 完成流式写入（修复无限等待）
---------------------------------------------------------------------
function M.finish()
	if not state.active then
		return false, "没有正在执行的流式任务", nil
	end

	if state.finished then
		return true,
			nil,
			{
				start_line = state.replace_start or state.start_line,
				end_line = state.current_line or state.end_line,
			}
	end

	state.closing = true

	local function do_finish()
		if state.finished then
			return true,
				nil,
				{
					start_line = state.replace_start or state.start_line,
					end_line = state.current_line or state.end_line,
				}
		end

		if state.writing or #state.queue > 0 then
			vim.defer_fn(do_finish, 10)
			return
		end

		state.finished = true
		state.closing = false

		local final_start = state.replace_start or state.start_line
		local final_end = state.replace_end or state.end_line

		local start_idx = final_start - 1
		local end_idx = final_end
		if start_idx > end_idx then
			end_idx = start_idx
		end

		-- ❗修复：只有在 AI 没写任何内容时才恢复原始代码
		if not state.current_line or state.current_line == final_start then
			safe_set_lines(state.bufnr, start_idx, end_idx, state.original_lines)
		end

		state.active = false

		return true, nil, {
			start_line = final_start,
			end_line = (state.current_line or final_start) - 1,
		}
	end

	vim.defer_fn(do_finish, 10)
	return true, nil, nil
end

---------------------------------------------------------------------
-- 4. abort(): 中断并恢复原始代码
---------------------------------------------------------------------
function M.abort()
	if not state.active or state.finished then
		return
	end

	state.closing = true
	state.finished = true

	vim.schedule(function()
		local start_idx = state.start_line - 1
		local end_idx = state.end_line
		if start_idx > end_idx then
			end_idx = start_idx
		end

		safe_set_lines(state.bufnr, start_idx, end_idx, state.original_lines)

		state.active = false
		state.closing = false
	end)
end

return M
