-- lua/todo2/ai/apply_stream.lua
-- 改进版：原位替换，不先删除代码

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

	-- 新增：替换模式相关
	replace_mode = "overwrite", -- "overwrite" 或 "insert"
	replaced_lines = {}, -- 已替换的行
	original_backup = {}, -- 完整备份

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

	-- 确保lines不为nil
	lines = lines or {}

	pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, start, finish, false, lines)
	end)
end

---------------------------------------------------------------------
-- 单线程写入队列处理器
---------------------------------------------------------------------
local function process_queue()
	if state.writing then
		return
	end
	if #state.queue == 0 then
		return
	end
	if state.finished then
		state.queue = {}
		return
	end

	state.writing = true

	local task = table.remove(state.queue, 1)

	-- 记录已替换的行
	for i, line in ipairs(task.lines) do
		local line_num = task.start + i
		state.replaced_lines[line_num] = line
	end

	safe_set_lines(task.bufnr, task.start, task.finish, task.lines)

	if state.current_line then
		state.current_line = state.current_line + #task.lines
	end

	pcall(function()
		vim.cmd("silent! undojoin")
	end)

	state.writing = false

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
-- 1. start(): 初始化流式写入（改进版：不先删除）
---------------------------------------------------------------------
function M.start(opts)
	if state.active then
		return false, "已有流式任务正在执行"
	end

	local bufnr = vim.fn.bufnr(opts.path)
	if bufnr == -1 then
		return false, "找不到 buffer: " .. opts.path
	end

	-- 获取原始代码区域
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
	state.original_backup = vim.deepcopy(original) -- 完整备份
	state.replaced_lines = {} -- 清空替换记录
	state.chunks = {}
	state.queue = {}
	state.writing = false

	state.replace_parsed = false
	state.replace_start = nil
	state.replace_end = nil
	state.header_removed = false
	state.current_line = nil
	state.header_buffer = ""

	-- ❗ 改进：不再立即删除代码，而是准备进行原位替换
	-- 只是在buffer上标记一个"正在修改"的虚拟文本或高亮（可选）
	vim.schedule(function()
		if state.finished then
			return
		end

		-- 可选：添加高亮提示正在修改
		pcall(function()
			-- 可以在这里添加虚拟文本提示："AI正在生成代码..."
			local ns = vim.api.nvim_create_namespace("todo2_ai_stream")
			vim.api.nvim_buf_clear_namespace(bufnr, ns, opts.ctx.start_line - 1, opts.ctx.end_line)
			vim.api.nvim_buf_set_extmark(bufnr, ns, opts.ctx.start_line - 1, 0, {
				virt_text = { { "🤖 AI正在生成代码...", "Comment" } },
				virt_text_pos = "overlay",
				hl_mode = "combine",
			})
		end)
	end)

	return true
end

---------------------------------------------------------------------
-- 2. on_chunk(): 接收 AI 的流式输出
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

			-- 移除REPLACE头，处理剩余内容
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
								-- ❗ 改进：原位替换，从replace_start开始覆盖
								local unique_lines = {}
								local last_line = ""
								for _, line in ipairs(lines) do
									if line ~= last_line then
										table.insert(unique_lines, line)
										last_line = line
									end
								end

								-- 计算需要替换的行范围
								local target_end = state.current_line + #unique_lines - 1
								table.insert(state.queue, {
									bufnr = state.bufnr,
									start = state.current_line - 1,
									finish = target_end - 1, -- 替换这些行
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

	-- 去重逻辑
	local last_task = state.queue[#state.queue]
	if last_task and #last_task.lines > 0 then
		local last_line = last_task.lines[#last_task.lines]
		if lines[1] == last_line then
			table.remove(lines, 1)
		end
	end

	if #lines > 0 then
		-- ❗ 改进：原位替换，覆盖原有行
		table.insert(state.queue, {
			bufnr = state.bufnr,
			start = state.current_line - 1,
			finish = state.current_line - 1 + #lines - 1, -- 替换连续的行
			lines = lines,
		})
		vim.schedule(process_queue)
	end
end

---------------------------------------------------------------------
-- 3. finish(): 完成流式写入
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

	-- 清除虚拟文本提示
	local ns = vim.api.nvim_create_namespace("todo2_ai_stream")
	vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)

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

		-- ❗ 改进：如果写入的行数少于原区域，删除多余的行
		if state.current_line and state.current_line < final_end then
			local start_idx = state.current_line - 1
			local end_idx = final_end
			safe_set_lines(state.bufnr, start_idx, end_idx, {})
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

	-- 清除虚拟文本提示
	local ns = vim.api.nvim_create_namespace("todo2_ai_stream")
	vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)

	vim.schedule(function()
		-- ❗ 改进：恢复原始代码（只恢复被修改的部分）
		if state.replace_parsed then
			-- 如果有REPLACE信息，只恢复那个区域
			local start_idx = state.replace_start - 1
			local end_idx = state.replace_end
			local original_section = {}
			for i = state.replace_start, state.replace_end do
				table.insert(original_section, state.original_backup[i - state.start_line + 1])
			end
			safe_set_lines(state.bufnr, start_idx, end_idx, original_section)
		else
			-- 否则恢复整个区域
			local start_idx = state.start_line - 1
			local end_idx = state.end_line
			safe_set_lines(state.bufnr, start_idx, end_idx, state.original_backup)
		end

		state.active = false
		state.closing = false
	end)
end

---------------------------------------------------------------------
-- 5. 状态查询（用于UI）
---------------------------------------------------------------------
function M.get_status()
	if not state.active then
		return {
			running = false,
			status = "idle",
			message = "空闲",
		}
	end

	local status_info = {
		running = true,
		active = state.active,
		closing = state.closing,
		finished = state.finished,
		writing = state.writing,
		queue_size = #state.queue,
		current_line = state.current_line,
		replaced_count = 0,
		total_lines = 0,
		message = "",
	}

	-- 计算已替换的行数
	if state.replace_start and state.replace_end then
		status_info.total_lines = state.replace_end - state.replace_start + 1
		for i = state.replace_start, state.replace_end do
			if state.replaced_lines[i] then
				status_info.replaced_count = status_info.replaced_count + 1
			end
		end
	elseif state.start_line and state.end_line then
		status_info.total_lines = state.end_line - state.start_line + 1
		for i = state.start_line, state.end_line do
			if state.replaced_lines[i] then
				status_info.replaced_count = status_info.replaced_count + 1
			end
		end
	end

	if status_info.total_lines > 0 then
		status_info.progress = math.floor((status_info.replaced_count / status_info.total_lines) * 100)
	end

	if state.finished then
		status_info.status = "completed"
		status_info.message = string.format("已完成 (%d%%)", status_info.progress or 100)
	elseif state.closing then
		status_info.status = "closing"
		status_info.message = string.format("正在完成... (%d%%)", status_info.progress or 0)
	elseif state.writing then
		status_info.status = "writing"
		status_info.message = string.format("正在写入... (%d%%)", status_info.progress or 0)
	else
		status_info.status = "waiting"
		status_info.message = string.format("等待数据... (%d%%)", status_info.progress or 0)
	end

	return status_info
end

function M.is_running()
	return state.active and not state.finished
end

return M
