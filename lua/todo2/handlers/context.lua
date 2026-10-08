-- lua/todo2/handlers/context.lua
-- :TodoContext —— 组装当前任务上下文（供 AI / 外部工具），复制到剪贴板或用 scratch 打开。

local M = {}

local ctx = require("todo2.ai")
local picker = require("todo2.task.picker")
local scratch = require("todo2.ui.scratch")

--- 复制指定任务的上下文到剪贴板（供抽屉等按 id 调用）。
---@param id string
---@param format? "markdown"|"json"
---@return boolean
function M.copy_id(id, format)
	format = format or "markdown"
	local bundle = ctx.build(id, {})
	if not bundle then
		vim.notify("Task does not exist: " .. tostring(id), vim.log.levels.ERROR)
		return false
	end
	local text = format == "json" and ctx.to_json(bundle) or ctx.to_markdown(bundle)
	vim.fn.setreg('"', text)
	pcall(vim.fn.setreg, "+", text)
	vim.notify(("Copied task context for %s (%s · %d chars)"):format(id, format, #text), vim.log.levels.INFO)
	return true
end

--- :TodoContext [markdown|json]；加 ! 时用 scratch 打开而不是复制。
---@param args table user command args
function M.show_context(args)
	local format = (args.args ~= "" and args.args) or "markdown"
	if format ~= "markdown" and format ~= "json" then
		vim.notify("Unknown format: " .. format .. " (options: markdown / json)", vim.log.levels.ERROR)
		return
	end

	picker.pick({ none_msg = "No task on the current line" }, function(task)
		if not args.bang then
			M.copy_id(task.id, format)
			return
		end

		local bundle = ctx.build(task.id, {})
		if not bundle then
			vim.notify("Task does not exist: " .. task.id, vim.log.levels.ERROR)
			return
		end
		scratch.open(format == "json" and ctx.to_json(bundle) or ctx.to_markdown(bundle), format)
		vim.notify("Task context opened (scratch)", vim.log.levels.INFO)
	end)
end

return M
