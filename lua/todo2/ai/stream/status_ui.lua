-- lua/todo2/ai/stream/status_ui.lua
-- 动态 UI：虚拟图标 + 动态动画 + 独立 UI 行 + 进度条 + ETA

local M = {}

local ns = vim.api.nvim_create_namespace("todo2_ai_stream")

------------------------------------------------------------
-- 动态图标帧（旋转动画）
------------------------------------------------------------
local ICON_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local frame_index = 1

local function next_icon()
	frame_index = frame_index + 1
	if frame_index > #ICON_FRAMES then
		frame_index = 1
	end
	return ICON_FRAMES[frame_index]
end

------------------------------------------------------------
-- 全局动画定时器（每 80ms 刷新一次）
------------------------------------------------------------
local timer = vim.loop.new_timer()

function M.start_animation(bufnr, state)
	timer:start(
		0,
		80,
		vim.schedule_wrap(function()
			if not state.active then
				return
			end
			M.update(bufnr, state)
		end)
	)
end

function M.stop_animation()
	timer:stop()
end

------------------------------------------------------------
-- 计算 UI 行（任务标记上一行）
------------------------------------------------------------
local function get_ui_line(ctx)
	local line = ctx.start_line - 4
	if line < 0 then
		line = ctx.start_line - 1
	end
	return line
end

------------------------------------------------------------
-- 确保 UI 行是一个真正的空行
------------------------------------------------------------
local function ensure_ui_line(bufnr, line)
	local total = vim.api.nvim_buf_line_count(bufnr)

	if line + 1 > total then
		vim.api.nvim_buf_set_lines(bufnr, total, total, false, { "" })
		return
	end

	local text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
	if text ~= "" then
		vim.api.nvim_buf_set_lines(bufnr, line, line, false, { "" })
	end
end

------------------------------------------------------------
-- 生成进度条
------------------------------------------------------------
local function make_progress_bar(progress)
	local total = 20
	local filled = math.floor(progress * total)
	local empty = total - filled
	return string.rep("█", filled) .. string.rep("░", empty)
end

------------------------------------------------------------
-- 计算 ETA（秒）
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
-- 动态 UI：根据状态渲染
------------------------------------------------------------
function M.update(bufnr, state)
	if not bufnr or bufnr == -1 then
		return
	end
	if not state.active then
		return
	end

	local ctx = state.ctx
	if not ctx then
		return
	end

	local line = get_ui_line(ctx)

	ensure_ui_line(bufnr, line)

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local icon = next_icon()
	local text = ""

	if state.finished then
		text = "✔ 已完成"
	elseif state.closing then
		text = icon .. " 正在完成..."
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
		local percent = string.format("%d%%", math.floor(progress * 100))

		local eta = calc_eta(state)
		local eta_text = eta and string.format(" | ETA：%.1f 秒", eta) or ""

		text = icon .. " " .. bar .. " " .. percent .. eta_text
	else
		text = icon .. " 等待模型响应..."
	end

	vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
		virt_text = { { text, "Comment" } },
		virt_text_pos = "overlay",
		hl_mode = "combine",
	})
end

------------------------------------------------------------
-- 清除 UI（删除 UI 行）
------------------------------------------------------------
function M.clear(bufnr, state)
	M.stop_animation()

	if not bufnr or bufnr == -1 then
		return
	end

	local ctx = state and state.ctx
	if not ctx then
		return
	end

	local line = get_ui_line(ctx)

	pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, line, line + 1, false, {})
	end)

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

return M
