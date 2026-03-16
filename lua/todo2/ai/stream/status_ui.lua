-- lua/todo2/ai/stream/status_ui.lua
local M = {}

local ns = vim.api.nvim_create_namespace("todo2_ai_stream")

------------------------------------------------------------
-- 所有任务
------------------------------------------------------------
M.tasks = {}

------------------------------------------------------------
-- spinner frames
------------------------------------------------------------
local ICON_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

------------------------------------------------------------
-- 动态省略号
------------------------------------------------------------
local DOT_FRAMES = { ".....", "....", "...", "..", ".", "" }

------------------------------------------------------------
-- progress bar
------------------------------------------------------------
local function make_progress_bar(progress)
	local total = 14
	local filled = math.floor(progress * total)
	local empty = total - filled
	return string.rep("█", filled) .. string.rep("░", empty)
end

------------------------------------------------------------
-- ETA
------------------------------------------------------------
local function calc_eta(state)
	if not state.start_time then
		return nil
	end
	local start = state.range.start_line
	local finish = state.range.end_line
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
-- 创建任务 UI
------------------------------------------------------------
function M.create(task_id, bufnr, state)
	local task = {}
	task.bufnr = bufnr
	task.state = state
	task.frame = 1
	task.dot = 1
	task.hover = false
	task.mark = nil
	task.closed = false -- ⭐ 防止重复关闭 timer
	task.timer = vim.loop.new_timer()

	M.tasks[task_id] = task

	task.timer:start(
		0,
		80,
		vim.schedule_wrap(function()
			M.update(task_id)
		end)
	)
end

------------------------------------------------------------
-- 停止动画（安全关闭）
------------------------------------------------------------
function M.stop_animation(task_id)
	local task = M.tasks[task_id]
	if not task or task.closed then
		return
	end

	if task.timer then
		task.timer:stop()
		task.timer:close()
	end

	task.closed = true
end

------------------------------------------------------------
-- 删除任务 UI（彻底清理）
------------------------------------------------------------
function M.remove(task_id)
	local task = M.tasks[task_id]
	if not task then
		return
	end

	M.stop_animation(task_id)

	if task.mark then
		pcall(vim.api.nvim_buf_del_extmark, task.bufnr, ns, task.mark)
	end

	M.tasks[task_id] = nil
end

------------------------------------------------------------
-- 更新 UI
------------------------------------------------------------
function M.update(task_id)
	local task = M.tasks[task_id]

	-- ⭐ 任务不存在 → 停止 timer
	if not task then
		M.stop_animation(task_id)
		return
	end

	local state = task.state
	local bufnr = task.bufnr

	-- ⭐ 任务结束/失败 → 自动 remove
	if state.finished or not state.active then
		M.remove(task_id)
		return
	end

	-- 动画
	local icon = ICON_FRAMES[task.frame]
	task.frame = (task.frame % #ICON_FRAMES) + 1
	local dots = DOT_FRAMES[task.dot]
	task.dot = (task.dot % #DOT_FRAMES) + 1
	local model = state.model_full_name or "AI"

	local text = ""
	if state.finished then
		text = "✔ " .. model .. " finished"
	elseif state.closing then
		text = icon .. " " .. model .. " finishing" .. dots
	elseif state.writing then
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
		text = icon .. " " .. model .. "  " .. bar .. " " .. percent .. "%" .. eta_text
	else
		text = icon .. " " .. model .. " waiting" .. dots
	end

	local stop_hl = task.hover and "IncSearch" or "DiagnosticError"

	if task.mark then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, task.mark)
	end

	task.mark = vim.api.nvim_buf_set_extmark(bufnr, ns, state.marker_line - 1, 0, {
		virt_lines = { {
			{ "󰅖", stop_hl },
			{ " " .. text, "Comment" },
		} },
		virt_lines_above = true,
		hl_mode = "combine",
	})
end

------------------------------------------------------------
-- hover 检测
------------------------------------------------------------
function M.update_hover()
	local pos = vim.fn.getmousepos()
	if not pos.winid then
		return
	end
	local bufnr = vim.api.nvim_win_get_buf(pos.winid)
	for id, task in pairs(M.tasks) do
		if task.bufnr ~= bufnr then
			task.hover = false
		else
			local row = task.state.marker_line
			task.hover = pos.line == row and pos.column <= 1
		end
		M.update(id)
	end
end

------------------------------------------------------------
-- 点击 stop
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
end

return M
