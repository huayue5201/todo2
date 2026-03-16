-- lua/todo2/command.lua
-- 命令模块（适配任务驱动智能编辑器模式）

local M = {}

function M.setup()
	---------------------------------------------------------------------
	-- 归档命令（保持原样）
	---------------------------------------------------------------------
	vim.api.nvim_create_user_command("Todo2Archive", function()
		local core = require("todo2.core")
		local bufnr = vim.api.nvim_get_current_buf()
		local ok, msg = core.archive_completed_tasks(bufnr)
		if ok then
			vim.notify(msg, vim.log.levels.INFO)
		else
			vim.notify(msg, vim.log.levels.WARN)
		end
	end, { desc = "归档已完成任务" })

	---------------------------------------------------------------------
	-- 智能预览（保持原样）
	---------------------------------------------------------------------
	vim.api.nvim_create_user_command("SmartPreview", function()
		require("todo2.keymaps.handlers").preview_content()
	end, { desc = "智能预览 TODO/代码" })

	---------------------------------------------------------------------
	-- 切换 AI 可执行标记（保持原样）
	---------------------------------------------------------------------
	vim.api.nvim_create_user_command("Todo2AIToggle", function()
		require("todo2.ai.commands.ai_toggle").toggle()
	end, { desc = "切换当前任务的 AI 可执行标记" })

	---------------------------------------------------------------------
	-- ⭐ 单任务执行（新架构：不再需要参数）
	---------------------------------------------------------------------
	vim.api.nvim_create_user_command("Todo2AIExecute", function()
		local executor_cmd = require("todo2.ai.commands.ai_execute")
		local ok, err = pcall(executor_cmd.execute)
		if not ok then
			vim.notify("Todo2AIExecute 失败: " .. tostring(err), vim.log.levels.ERROR)
		end
	end, {
		nargs = 0,
		desc = "执行当前任务（AI 智能编辑器模式）",
	})

	---------------------------------------------------------------------
	-- ⭐ 批量执行（新架构：不再需要参数）
	---------------------------------------------------------------------
	vim.api.nvim_create_user_command("Todo2AIExecuteAll", function()
		local executor_all = require("todo2.ai.commands.ai_execute_all")
		local ok, err = pcall(executor_all.execute_all)
		if not ok then
			vim.notify("Todo2AIExecuteAll 失败: " .. tostring(err), vim.log.levels.ERROR)
		end
	end, {
		nargs = 0,
		desc = "批量执行所有 AI 可执行任务",
	})
end

vim.api.nvim_create_user_command("TodoAISelectModel", function()
	require("todo2.ai.selector.fzf").select_model(function(cfg)
		require("todo2.ai").set_model(cfg)
		vim.notify("已切换模型：" .. cfg.display_name)
	end)
end, {})

vim.api.nvim_create_user_command("TodoAIStop", function()
	local ok, msg = require("todo2.ai.stream.engine").stop()
	if not ok then
		vim.notify(msg, vim.log.levels.WARN)
	else
		vim.notify("AI 任务已终止", vim.log.levels.INFO)
	end
end, {})

return M
