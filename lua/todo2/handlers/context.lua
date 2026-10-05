-- lua/todo2/handlers/context.lua
-- :TodoContext —— 组装当前任务上下文（供 AI / 外部工具），复制到剪贴板或用 scratch 打开。

local M = {}

local ctx = require("todo2.ai")
local cursor = require("todo2.task.cursor")

--- 在右侧打开一个只读 scratch buffer 展示文本。
---@param text string
---@param format string
local function open_scratch(text, format)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.split(text, "\n", true))
	vim.api.nvim_set_option_value("filetype", format == "json" and "json" or "markdown", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.cmd("botright vsplit")
	vim.api.nvim_win_set_buf(0, buf)
end

--- 复制指定任务的上下文到剪贴板（供抽屉等按 id 调用）。
---@param id string
---@param format? "markdown"|"json"
---@return boolean
function M.copy_id(id, format)
	format = format or "markdown"
	local bundle = ctx.build(id, {})
	if not bundle then
		vim.notify("任务不存在: " .. tostring(id), vim.log.levels.ERROR)
		return false
	end
	local text = format == "json" and ctx.to_json(bundle) or ctx.to_markdown(bundle)
	vim.fn.setreg('"', text)
	pcall(vim.fn.setreg, "+", text)
	vim.notify(("已复制 %s 的任务上下文（%s · %d 字符）"):format(id, format, #text), vim.log.levels.INFO)
	return true
end

--- :TodoContext [markdown|json]；加 ! 时用 scratch 打开而不是复制。
---@param args table user command args
function M.show_context(args)
	local id = cursor.get_id()
	if not id then
		vim.notify("当前行没有任务", vim.log.levels.WARN)
		return
	end

	local format = (args.args ~= "" and args.args) or "markdown"
	if format ~= "markdown" and format ~= "json" then
		vim.notify("未知格式: " .. format .. "（可选 markdown / json）", vim.log.levels.ERROR)
		return
	end

	if not args.bang then
		M.copy_id(id, format)
		return
	end

	local bundle = ctx.build(id, {})
	if not bundle then
		vim.notify("任务不存在: " .. id, vim.log.levels.ERROR)
		return
	end
	open_scratch(format == "json" and ctx.to_json(bundle) or ctx.to_markdown(bundle), format)
	vim.notify("任务上下文已打开（scratch）", vim.log.levels.INFO)
end

return M
