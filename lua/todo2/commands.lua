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

	vim.api.nvim_create_user_command("SmartPreview", function()
		require("todo2.keymaps.handlers").preview_content()
	end, {
		desc = "智能预览：标记行预览 TODO/代码",
	})

	vim.api.nvim_create_user_command("Todo2AIToggle", function()
		require("todo2.ai.commands.ai_toggle").toggle()
	end, {})

	vim.api.nvim_create_user_command("Todo2AIExecute", function()
		require("todo2.ai.commands.ai_execute").execute()
	end, {})
end

vim.api.nvim_create_user_command("Todo2AIExecuteAll", function()
	require("todo2.ai.commands.ai_execute_all").execute_all()
end, {})

return M
