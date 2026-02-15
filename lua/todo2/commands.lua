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

	-- 诊断存储问题
	vim.api.nvim_create_user_command("TodoDiagnoseStore", function()
		local ok, result = pcall(require, "todo2.debug.check_store")
		if ok then
			result.check_all_data()
		else
			print("诊断模块不存在，请先创建")
		end
	end, {})

	-- 修复存储问题
	vim.api.nvim_create_user_command("TodoFixStore", function()
		local ok, result = pcall(require, "todo2.debug.fix_store")
		if ok then
			result.fix_all_data()
		else
			print("修复模块不存在，请先创建")
		end
	end, {})
end

return M
