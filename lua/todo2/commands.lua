-- lua/todo2/commands.lua
-- 命令执行逻辑（命令注册在 plugin/todo2.lua，惰性触发）

local M = {}

--- :TodoSync —— 手动同步当前 TODO 文件
function M.sync_current()
	local conceal = require("todo2.render.conceal")
	local buffer = require("todo2.utils.buffer")
	local events = require("todo2.core.events")
	local sync = require("todo2.core.sync")
	local file = require("todo2.utils.file")

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
end

--- :Todo2Heatmap —— 打开任务状态热图
function M.open_heatmap()
	require("todo2.ui.heatmap").open()
end

--- :SmartPreview —— 智能预览 TODO/代码
function M.smart_preview()
	require("todo2.handlers").preview_content()
end

return M
