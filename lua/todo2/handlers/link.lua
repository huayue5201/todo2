-- lua/todo2/handlers/link.lua
-- 双链 / 预览处理器

local M = {}

local buffer = require("todo2.utils.buffer")
local line = require("todo2.utils.line")
local core = require("todo2.store.task.core")
local cursor = require("todo2.task.cursor")
local link_preview = require("todo2.task.preview")
local link_viewer = require("todo2.task.viewer")

--- 预览任务内容（代码预览或 TODO 预览）
function M.preview_content()
	local info = buffer.get_current_info()
	local task = nil

	if info.is_todo_file then
		local analysis = line.analyze_current_line()
		if analysis.id then
			task = core.get_task(analysis.id)
		end
	else
		task = cursor.get_task(info.bufnr, vim.fn.line("."))
	end

	if task then
		if info.is_todo_file then
			link_preview.preview_code()
		else
			link_preview.preview_todo()
		end
	end
end

--- 在 quickfix 中显示项目所有链接
function M.show_project_links_qf()
	link_viewer.show_project_links_qf()
end

--- 在 location list 中显示当前缓冲区链接
function M.show_buffer_links_loclist()
	link_viewer.show_buffer_links_loclist()
end

return M
