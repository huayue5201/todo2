-- lua/todo2/render/line_refresh.lua
-- 任务行重绘：写 store / 改文件行之后，把「这一行」的渲染（去掉旧 extmark、重新打
-- 高亮 / conceal / 标签色）和筛选可见性刷新干净。
--
-- :TodoDue 与 :TodoTag 原本各有一份逐行相同的实现，统一到这里。

local M = {}

local core = require("todo2.store.task.core")

--- 重绘某个任务在 TODO 文件里所在的哪一行（未打开 / 已卸载的缓冲区直接跳过）。
---@param id string
function M.task_line(id)
	if not id then
		return
	end
	local loc = core.get_todo_location(id)
	if not loc or not loc.path then
		return
	end
	local bufnr = vim.fn.bufnr(loc.path)
	if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	local ok, line = pcall(function()
		return vim.api.nvim_buf_get_lines(bufnr, loc.line - 1, loc.line, false)[1]
	end)
	if not ok or not line then
		return
	end
	pcall(function()
		require("todo2.render.todo_render").render_task_by_line(bufnr, loc.line, line)
		require("todo2.render.conceal").apply_line_conceal(bufnr, loc.line)
		require("todo2.render.filter").refresh(bufnr)
	end)
end

return M
