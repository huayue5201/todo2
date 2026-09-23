-- lua/todo2/commands.lua
-- 命令模块

local M = {}

function M.setup()
	local conceal = require("todo2.render.conceal")
	local file = require("todo2.utils.file")
	local buffer = require("todo2.utils.buffer")
	local events = require("todo2.core.events")
	local sync = require("todo2.core.sync")

	vim.api.nvim_create_user_command("TodoSync", function()
		local buf = vim.api.nvim_get_current_buf()
		local path = buffer.get_path(buf)
		if not file.is_todo_file(path) then
			vim.notify("不是TODO文件", vim.log.levels.ERROR)
			return
		end

		local result = sync.sync_todo_file(path)
		vim.notify(string.format("同步完成: %d 个任务变更", #result.changed_ids))

		events.emit("manual_sync", {
			file = path,
			bufnr = buf,
			changed_ids = result.changed_ids,
		})

		conceal.apply_buffer_conceal(buf)
	end, {})

	vim.api.nvim_create_user_command("Todo2Heatmap", function()
		require("todo2.ui.heatmap").open()
	end, { desc = "打开热图" })

	vim.api.nvim_create_user_command("SmartPreview", function()
		require("todo2.handlers").preview_content()
	end, { desc = "智能预览 TODO/代码" })
end

return M
