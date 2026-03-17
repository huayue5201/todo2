-- ai/dialog_box/input.lua
local M = {}

local input_win
local input_buf
local submit_cb

local config = {
	max_width_ratio = 0.8,
	border = "rounded",
}

local function calc_width()
	local win = vim.api.nvim_get_current_win()
	local w = vim.api.nvim_win_get_width(win)
	return math.max(30, math.floor(w * config.max_width_ratio))
end

function M.close()
	if input_win and vim.api.nvim_win_is_valid(input_win) then
		vim.api.nvim_win_close(input_win, true)
	end
	input_win = nil
	input_buf = nil
	submit_cb = nil
end

function M.open(row, on_submit)
	M.close()

	submit_cb = on_submit
	input_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

	local width = calc_width()
	local win = vim.api.nvim_get_current_win()
	local win_width = vim.api.nvim_win_get_width(win)
	local col = math.floor((win_width - width) / 2)

	input_win = vim.api.nvim_open_win(input_buf, true, {
		relative = "win",
		win = win,
		row = row,
		col = col,
		width = width,
		height = 1,
		style = "minimal",
		border = config.border,
		title = " 💬 输入消息 (回车发送) ",
		title_pos = "center",
	})

	local opts = { buffer = input_buf, noremap = true, silent = true }

	vim.keymap.set("i", "<CR>", function()
		local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
		local text = table.concat(lines, "\n")
		if text ~= "" and submit_cb then
			submit_cb(text)
		end
	end, opts)

	vim.keymap.set("i", "<Esc>", function()
		local text = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
		if text == "" then
			require("todo2.ai.dialog_box.controller").close()
		else
			vim.cmd("stopinsert")
		end
	end, opts)

	vim.keymap.set({ "i", "n" }, "<C-c>", function()
		require("todo2.ai.dialog_box.controller").stop_active()
	end, opts)

	vim.cmd("startinsert")
end

function M.reposition(row)
	if not input_win or not vim.api.nvim_win_is_valid(input_win) then
		return
	end

	local width = calc_width()
	local win = vim.api.nvim_get_current_win()
	local win_width = vim.api.nvim_win_get_width(win)
	local col = math.floor((win_width - width) / 2)

	vim.api.nvim_win_set_config(input_win, {
		relative = "win",
		win = win,
		row = row,
		col = col,
		width = width,
		height = 1,
	})
end

function M.set_text(text)
	if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { text })
		if input_win then
			vim.api.nvim_win_set_cursor(input_win, { 1, #text })
		end
	end
end

function M.is_open()
	return input_win and vim.api.nvim_win_is_valid(input_win)
end

return M
