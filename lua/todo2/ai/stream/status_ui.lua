local M = {}

local ns = vim.api.nvim_create_namespace("todo2_ai_stream")
local ui_mark_id = nil

local ICON_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local frame_index = 1

local function next_icon()
	frame_index = frame_index + 1
	if frame_index > #ICON_FRAMES then
		frame_index = 1
	end
	return ICON_FRAMES[frame_index]
end

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

local function make_progress_bar(progress)
	local total = 20
	local filled = math.floor(progress * total)
	local empty = total - filled
	return string.rep("█", filled) .. string.rep("░", empty)
end

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

function M.update(bufnr, state)
	if not bufnr or bufnr == -1 then
		return
	end
	if not state.active then
		return
	end

	-- ⭐ 必须使用 state.marker_line
	if not state.marker_line then
		return
	end

	-- ⭐ 补偿偏移：extmark 放在 marker_line + 1
	local line = state.marker_line + 1

	if ui_mark_id then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, ui_mark_id)
	end

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

	ui_mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, line - 3, 0, {
		virt_lines = {
			{ { text, "Comment" } },
		},
		virt_lines_above = true,
		hl_mode = "combine",
	})
end

function M.clear(bufnr)
	M.stop_animation()

	if ui_mark_id then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, ui_mark_id)
		ui_mark_id = nil
	end
end

return M
