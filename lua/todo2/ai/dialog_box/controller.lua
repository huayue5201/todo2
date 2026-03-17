-- ai/dialog_box/controller.lua
local session_mod = require("todo2.ai.dialog_box.session")
local chat_ui = require("todo2.ai.dialog_box.ui")
local input = require("todo2.ai.dialog_box.input")
local engine = require("todo2.ai.dialog_box.chat_engine")
local prompt_builder = require("todo2.ai.prompt")
local link = require("todo2.store.link")

local M = {}

local active = {
	task_id = nil,
	bufnr = nil,
	row = nil,
}

function M.stop_active()
	if active.task_id then
		engine.stop(active.task_id)
		chat_ui.render_status(active.bufnr, active.row + 1, { text = "已停止 AI 响应" })
	end
end

function M.open(task_id, bufnr, row)
	if active.task_id then
		M.close()
	end

	active.task_id = task_id
	active.bufnr = bufnr
	active.row = row

	local session = session_mod.get(task_id)

	chat_ui.clear(bufnr)
	chat_ui.render_messages(bufnr, row, session)
	chat_ui.render_status(bufnr, row + 1, { text = "[回车发送] [q关闭] [Ctrl+C停止]" })

	input.open(row + 2, function(text)
		M.send(task_id, bufnr, row, text)
	end)

	local opts = { buffer = bufnr, noremap = true, silent = true }
	vim.keymap.set("n", "q", function()
		M.close()
	end, opts)
	vim.keymap.set({ "n", "i" }, "<C-c>", function()
		M.stop_active()
	end, opts)
end

function M.send(task_id, bufnr, row, text)
	local session = session_mod.get(task_id)

	session_mod.add_message(task_id, {
		role = "user",
		content = text,
		timestamp = os.date("%H:%M:%S"),
	})

	chat_ui.render_messages(bufnr, row, session)
	chat_ui.render_status(bufnr, row + 1, { text = "AI 正在思考…" })
	input.set_text("")

	local task = link.get_task(task_id)
	if not task then
		task = {
			id = task_id,
			content = "任务 #" .. task_id,
			locations = {
				todo = {
					path = vim.api.nvim_buf_get_name(bufnr),
					line = row,
				},
			},
		}
	end

	local prompt = prompt_builder.build_with_chat(task, session.messages)

	engine.stop(task_id)

	engine.start(task_id, bufnr, prompt, {
		on_chunk = function(chunk)
			chat_ui.update_streaming(task_id, bufnr, row, session, chunk)
			chat_ui.render_status(bufnr, row + 1, { text = "AI 正在回答… (Ctrl+C 停止)" })
		end,
		on_finish = function()
			chat_ui.finish_streaming(task_id, bufnr, row, session)
			chat_ui.render_status(bufnr, row + 1, { text = "AI 响应完成" })
		end,
		on_error = function(msg)
			session_mod.add_message(task_id, {
				role = "system",
				content = "❌ " .. msg,
				timestamp = os.date("%H:%M:%S"),
			})
			chat_ui.render_messages(bufnr, row, session)
			chat_ui.render_status(bufnr, row + 1, { text = "AI 错误" })
		end,
	})
end

function M.close()
	if active.task_id then
		engine.stop(active.task_id)
	end

	if active.bufnr then
		chat_ui.clear(active.bufnr)
	end

	input.close()

	active.task_id = nil
	active.bufnr = nil
	active.row = nil
end

return M
