local M = {}

local ns = vim.api.nvim_create_namespace("todo2_ai_stream")

------------------------------------------------------------
-- 所有任务
------------------------------------------------------------
M.tasks = {}
M.pending_updates = {} -- 待更新队列
M.update_pending = false
M.animation_pending = false -- 动画待更新标志

------------------------------------------------------------
-- spinner frames
------------------------------------------------------------
local ICON_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

------------------------------------------------------------
-- 动态省略号
------------------------------------------------------------
local DOT_FRAMES = { ".....", "....", "...", "..", ".", "" }

------------------------------------------------------------
-- 调试模式
------------------------------------------------------------
local DEBUG = false

local function debug_log(task_id, message)
	if DEBUG then
		print(string.format("[UI-%s] %s", task_id or "global", message))
	end
end

------------------------------------------------------------
-- 进度条
------------------------------------------------------------
local function make_progress_bar(progress)
	local total = 14
	local filled = math.floor(progress * total)
	local empty = total - filled
	return string.rep("█", filled) .. string.rep("░", empty)
end

------------------------------------------------------------
-- ETA计算
------------------------------------------------------------
local function calc_eta(state)
	if not state.start_time then
		return nil
	end
	local start = state.range and state.range.start_line or state.ctx.start_line
	local finish = state.range and state.range.end_line or state.ctx.end_line
	local cur = state.current_line or start
	local total = finish - start
	if total <= 0 then
		return nil
	end
	local progress = (cur - start) / total
	if progress <= 0 then
		return nil
	end
	local elapsed = vim.loop.now() / 1000 - state.start_time
	if elapsed <= 0 then
		return nil
	end
	local speed = progress / elapsed
	if speed <= 0 then
		return nil
	end
	return (1 - progress) / speed
end

------------------------------------------------------------
-- 格式化进度显示
------------------------------------------------------------
local function format_progress(state)
	if not state.range then
		return "定位中..."
	end

	local start = state.range.start_line
	local finish = state.range.end_line
	local cur = state.current_line or start
	local progress = 0
	if finish > start then
		progress = (cur - start) / (finish - start)
		progress = math.max(0, math.min(progress, 1))
	end
	local bar = make_progress_bar(progress)
	local percent = math.floor(progress * 100)
	local eta = calc_eta(state)
	local eta_text = eta and string.format(" ETA %.1fs", eta) or ""
	return bar .. " " .. percent .. "%" .. eta_text
end

------------------------------------------------------------
-- 获取动画帧
------------------------------------------------------------
local function get_animation_frame(task_id)
	local task = M.tasks[task_id]
	if not task then
		return "⠋"
	end
	return ICON_FRAMES[task.frame] or "⠋"
end

------------------------------------------------------------
-- 获取省略号
------------------------------------------------------------
local function get_dots(task_id)
	local task = M.tasks[task_id]
	if not task then
		return "..."
	end
	return DOT_FRAMES[task.dot] or ""
end

------------------------------------------------------------
-- 生成显示文本
------------------------------------------------------------
local function generate_display_text(task_id, state)
	local icon = get_animation_frame(task_id)
	local model = state.model_full_name or "AI"

	-- 错误状态优先显示
	if state.error_message then
		return "✗ " .. model .. " failed"
	end

	-- 完成状态
	if state.finished then
		return "✔ " .. model .. " finished"
	end

	-- 正在关闭
	if state.closing then
		return icon .. " " .. model .. " finishing" .. get_dots(task_id)
	end

	-- 正在写入（有进度条）
	if state.writing and state.range then
		return icon .. " " .. model .. "  " .. format_progress(state)
	end

	-- 正在写入但还未定位（不应该发生，但以防万一）
	if state.writing then
		return icon .. " " .. model .. " writing" .. get_dots(task_id)
	end

	-- 队列中有等待写入的内容
	if state.queue and #state.queue > 0 then
		return icon .. " " .. model .. " waiting" .. get_dots(task_id)
	end

	-- 已经接收到内容但还没开始写入
	if state.received_chunk and state.range then
		return icon .. " " .. model .. " ready" .. get_dots(task_id)
	end

	-- 协议解析中
	if not state.protocol then
		return icon .. " " .. model .. " connecting" .. get_dots(task_id)
	end

	-- 定位中
	if state.protocol and not state.range then
		return icon .. " " .. model .. " locating" .. get_dots(task_id)
	end

	-- 默认等待状态
	return icon .. " " .. model .. " waiting" .. get_dots(task_id)
end

------------------------------------------------------------
-- 刷新单个任务UI
------------------------------------------------------------
local function refresh_task(task_id)
	local task = M.tasks[task_id]
	if not task then
		debug_log(task_id, "Task not found for refresh")
		return
	end

	local state = task.state
	local bufnr = task.bufnr

	-- 检查buffer是否有效
	if not bufnr or bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
		debug_log(task_id, "Invalid buffer, cleaning up")
		M._cleanup_task(task_id)
		return
	end

	-- 检查任务是否应该被移除
	if state.finished or not state.active then
		debug_log(task_id, "Task finished/inactive, cleaning up")
		M._cleanup_task(task_id)
		return
	end

	-- 生成显示文本
	local text = generate_display_text(task_id, state)
	local stop_hl = task.hover and "IncSearch" or "DiagnosticError"

	-- 更新extmark
	if task.mark then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, task.mark)
	end

	local ok, mark = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, state.marker_line - 1, 0, {
		virt_lines = { {
			{ "✘", stop_hl },
			{ " " .. text, "Comment" },
		} },
		virt_lines_above = true,
		hl_mode = "combine",
	})

	if ok then
		task.mark = mark
		debug_log(task_id, "UI updated: " .. text)
	else
		debug_log(task_id, "Failed to set extmark")
	end
end

------------------------------------------------------------
-- 清理任务
------------------------------------------------------------
function M._cleanup_task(task_id)
	local task = M.tasks[task_id]
	if not task then
		return
	end

	debug_log(task_id, "Cleaning up task")

	-- 删除extmark
	if task.mark and task.bufnr and vim.api.nvim_buf_is_valid(task.bufnr) then
		pcall(vim.api.nvim_buf_del_extmark, task.bufnr, ns, task.mark)
	end

	-- 从任务列表中移除
	M.tasks[task_id] = nil

	-- 从待更新队列中移除
	M.pending_updates[task_id] = nil
end

------------------------------------------------------------
-- 批量更新调度（用于状态变更）
------------------------------------------------------------
local schedule_batch_update = vim.schedule_wrap(function()
	if not M.update_pending then
		return
	end
	M.update_pending = false

	debug_log(nil, "Batch updating " .. vim.tbl_count(M.pending_updates) .. " tasks")

	-- 批量处理所有待更新任务
	for task_id, _ in pairs(M.pending_updates) do
		refresh_task(task_id)
	end
	M.pending_updates = {}
end)

------------------------------------------------------------
-- 动画更新调度（专门用于动画）
------------------------------------------------------------
local schedule_animation_update = vim.schedule_wrap(function()
	if not M.animation_pending then
		return
	end
	M.animation_pending = false

	local has_active = false
	for task_id, task in pairs(M.tasks) do
		if task.state and task.state.active and not task.state.finished then
			has_active = true
			-- 更新动画帧
			task.frame = (task.frame % #ICON_FRAMES) + 1
			task.dot = (task.dot % #DOT_FRAMES) + 1
			-- 加入待更新队列
			M.pending_updates[task_id] = true
		end
	end

	if has_active then
		-- 触发UI更新
		if not M.update_pending then
			M.update_pending = true
			schedule_batch_update()
		end
	end
end)

------------------------------------------------------------
-- 启动动画定时器
------------------------------------------------------------
local function start_animation_timer()
	if M.animation_timer then
		return
	end

	M.animation_timer = vim.loop.new_timer()
	M.animation_timer:start(0, 80, function()
		-- 只要有活动任务，就标记动画待更新
		for task_id, task in pairs(M.tasks) do
			if task.state and task.state.active and not task.state.finished then
				if not M.animation_pending then
					M.animation_pending = true
					schedule_animation_update()
				end
				return
			end
		end
	end)

	debug_log(nil, "Animation timer started")
end

------------------------------------------------------------
-- 请求更新（由engine调用）
------------------------------------------------------------
function M.request_update(task_id)
	if not M.tasks[task_id] then
		debug_log(task_id, "Update requested but task not found")
		return
	end

	M.pending_updates[task_id] = true

	if not M.update_pending then
		M.update_pending = true
		schedule_batch_update()
		debug_log(task_id, "Update scheduled")
	else
		debug_log(task_id, "Update queued")
	end
end

------------------------------------------------------------
-- 创建任务UI
------------------------------------------------------------
function M.create(task_id, bufnr, state)
	debug_log(task_id, "Creating UI for task")

	local task = {
		bufnr = bufnr,
		state = state,
		frame = 1,
		dot = 1,
		hover = false,
		mark = nil,
	}

	M.tasks[task_id] = task
	start_animation_timer() -- 确保定时器已启动

	-- 立即显示初始状态
	M.request_update(task_id)
end

------------------------------------------------------------
-- 停止动画（移除任务时会自动停止，不需要单独停止定时器）
------------------------------------------------------------
function M.stop_animation(task_id)
	-- 只是标记，不需要特殊处理
	debug_log(task_id, "Animation stopped")
end

------------------------------------------------------------
-- 删除任务UI
------------------------------------------------------------
function M.remove(task_id)
	debug_log(task_id, "Removing UI")
	M._cleanup_task(task_id)

	-- 如果没有任务了，可以停止定时器（可选）
	if vim.tbl_isempty(M.tasks) and M.animation_timer then
		M.animation_timer:stop()
		M.animation_timer:close()
		M.animation_timer = nil
		debug_log(nil, "Animation timer stopped")
	end
end

------------------------------------------------------------
-- hover检测
------------------------------------------------------------
function M.update_hover()
	local pos = vim.fn.getmousepos()
	if not pos.winid then
		return
	end

	local bufnr = vim.api.nvim_win_get_buf(pos.winid)
	local needs_update = false

	for id, task in pairs(M.tasks) do
		local old_hover = task.hover
		if task.bufnr ~= bufnr then
			task.hover = false
		else
			local row = task.state.marker_line
			task.hover = pos.line == row and pos.column <= 1
		end

		if old_hover ~= task.hover then
			needs_update = true
			M.request_update(id)
		end
	end

	if needs_update then
		debug_log(nil, "Hover state changed")
	end
end

------------------------------------------------------------
-- 点击stop
------------------------------------------------------------
function M.click()
	local pos = vim.fn.getmousepos()
	if not pos.winid then
		return
	end

	local bufnr = vim.api.nvim_win_get_buf(pos.winid)
	for id, task in pairs(M.tasks) do
		if task.bufnr == bufnr then
			local row = task.state.marker_line
			if pos.line == row and pos.column <= 1 then
				debug_log(id, "Stop button clicked")
				require("todo2.ai.stream.engine").stop(id)
				return
			end
		end
	end
end

------------------------------------------------------------
-- 初始化鼠标事件
------------------------------------------------------------
if not M._init then
	vim.keymap.set("n", "<LeftMouse>", M.click, { noremap = true, silent = true })
	vim.api.nvim_create_autocmd("CursorMoved", { callback = M.update_hover })
	M._init = true
	debug_log(nil, "Status UI initialized")
end

return M
