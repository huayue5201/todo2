-- lua/todo2/command.lua
--- @module todo2.commands
--- @brief 命令模块（极简版）

local M = {}

function M.setup()
	-- 归档命令
	vim.api.nvim_create_user_command("Todo2Archive", function()
		local core = require("todo2.core")
		local bufnr = vim.api.nvim_get_current_buf()

		local success, msg, count = core.archive_completed_tasks(bufnr)

		if success then
			vim.notify(msg, vim.log.levels.INFO)
		else
			vim.notify(msg, vim.log.levels.WARN)
		end
	end, {
		desc = "归档已完成的任务（删除代码标记，移动到归档区域）",
	})
end

return M
