-- NOTE:ref:e813c6
-- ai/dialog_box/ui.lua
local ns_messages = vim.api.nvim_create_namespace("todo2_ai_dialog_messages")
local ns_status = vim.api.nvim_create_namespace("todo2_ai_dialog_status")

local M = {}

local config = {
	max_width = 60,
	max_messages = 20, -- ⭐ 限制消息区最大条数
	colors = {
		user = "String",
		assistant = "Special",
		system = "Comment",
		timestamp = "Comment",
		status = "WarningMsg",
	},
}

local function wrap(text, max_width)
	local out = {}
	for line in tostring(text):gmatch("[^\n]*") do
		while #line > max_width do
			table.insert(out, line:sub(1, max_width))
			line = line:sub(max_width + 1)
		end
		table.insert(out, line)
	end
	return out
end

local function render_message(msg)
	local role = msg.role
	local ts = msg.timestamp
	local color = config.colors[role] or "Normal"

	local header = string.format("[%s] %s", role == "user" and "你" or (role == "assistant" and "AI" or "系统"), ts)

	local lines = {
		{ { " " .. header, config.colors.timestamp } },
	}

	for _, l in ipairs(wrap(msg.content, config.max_width)) do
		table.insert(lines, { { " " .. l, color } })
	end

	table.insert(lines, { { " ", "Normal" } })
	return lines
end

function M.clear(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, ns_messages, 0, -1)
	vim.api.nvim_buf_clear_namespace(bufnr, ns_status, 0, -1)
end

function M.render_messages(bufnr, row, session)
	vim.api.nvim_buf_clear_namespace(bufnr, ns_messages, 0, -1)

	local msgs = session.messages
	local start = math.max(1, #msgs - config.max_messages + 1)
	local virt = {}

	for i = start, #msgs do
		local block = render_message(msgs[i])
		for _, l in ipairs(block) do
			table.insert(virt, l)
		end
	end

	vim.api.nvim_buf_set_extmark(bufnr, ns_messages, row, 0, {
		virt_lines = virt,
		virt_lines_above = false,
	})
end

function M.render_status(bufnr, row, opts)
	vim.api.nvim_buf_clear_namespace(bufnr, ns_status, 0, -1)
	if not opts or not opts.text then
		return
	end

	vim.api.nvim_buf_set_extmark(bufnr, ns_status, row, 0, {
		virt_lines = {
			{ { " " .. opts.text, config.colors.status } },
		},
	})
end

function M.update_streaming(task_id, bufnr, row, session, chunk)
	local last = session.messages[#session.messages]
	if not last or last.role ~= "assistant" or not last.streaming then
		table.insert(session.messages, {
			role = "assistant",
			content = chunk,
			timestamp = os.date("%H:%M:%S"),
			streaming = true,
		})
	else
		last.content = last.content .. chunk
	end

	M.render_messages(bufnr, row, session)
end

function M.finish_streaming(task_id, bufnr, row, session)
	local last = session.messages[#session.messages]
	if last and last.streaming then
		last.streaming = nil
	end
	M.render_messages(bufnr, row, session)
end

return M
