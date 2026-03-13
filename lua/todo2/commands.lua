-- lua/todo2/command.lua
--- @module todo2.commands
--- @brief 命令模块（增强版：支持 AI 模式参数）

local M = {}

local function parse_args(argstr)
	-- 简单解析空格分隔的参数：mode force use_cache
	-- 示例: "patch force=false use_cache=true"
	local opts = {}
	if not argstr or argstr == "" then
		return opts
	end
	for token in argstr:gmatch("%S+") do
		local k, v = token:match("^(%w+)%=(.+)$")
		if k then
			if v == "true" then
				opts[k] = true
			elseif v == "false" then
				opts[k] = false
			else
				opts[k] = v
			end
		else
			-- 如果只是单个词，视为 mode
			if not opts.mode then
				opts.mode = token
			end
		end
	end
	return opts
end

function M.setup()
	-- 归档命令（保持原样）
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

	-- 智能预览（保持原样）
	vim.api.nvim_create_user_command("SmartPreview", function()
		require("todo2.keymaps.handlers").preview_content()
	end, {
		desc = "智能预览：标记行预览 TODO/代码",
	})

	-- 切换 AI 可执行标记（保留原有 toggle 命令）
	vim.api.nvim_create_user_command("Todo2AIToggle", function()
		require("todo2.ai.commands.ai_toggle").toggle()
	end, {
		desc = "切换当前任务的 AI 可执行标记",
	})

	-- 单个任务执行：支持可选参数（mode, force, use_cache）
	vim.api.nvim_create_user_command("Todo2AIExecute", function(opts)
		-- opts.args 是命令行传入的字符串
		local parsed = parse_args(opts.args)
		-- 如果没有传 mode，默认使用 full（executor 内也有默认）
		local mode = parsed.mode
		local force = parsed.force
		local use_cache = parsed.use_cache

		-- 调用 ai_execute 模块（模块内部负责定位当前任务 id）
		local executor_cmd = require("todo2.ai.commands.ai_execute")
		local ok, err = pcall(function()
			executor_cmd.execute({
				mode = mode,
				force = force,
				use_cache = use_cache,
			})
		end)
		if not ok then
			vim.notify("Todo2AIExecute 失败: " .. tostring(err), vim.log.levels.ERROR)
		end
	end, {
		nargs = "*",
		desc = "对当前任务执行 AI（可选参数：mode=full|patch|diff force=true|false use_cache=true|false）",
	})

	-- 批量执行（所有可执行任务）
	vim.api.nvim_create_user_command("Todo2AIExecuteAll", function(opts)
		local parsed = parse_args(opts.args)
		local mode = parsed.mode
		local force = parsed.force
		local use_cache = parsed.use_cache

		local executor_all = require("todo2.ai.commands.ai_execute_all")
		local ok, err = pcall(function()
			executor_all.execute_all({
				mode = mode,
				force = force,
				use_cache = use_cache,
			})
		end)
		if not ok then
			vim.notify("Todo2AIExecuteAll 失败: " .. tostring(err), vim.log.levels.ERROR)
		end
	end, {
		nargs = "*",
		desc = "对所有 AI 可执行任务批量执行（可选参数同 Todo2AIExecute）",
	})
end

return M
