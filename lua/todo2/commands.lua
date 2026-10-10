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
		vim.notify("Not a TODO file", vim.log.levels.ERROR)
		return
	end

	local result = sync.sync_todo_file(path)
	vim.notify(string.format("Sync complete: %d task changes", #result.changed_ids))

	events.emit("manual_sync", {
		file = path,
		bufnr = buf,
		changed_ids = result.changed_ids,
	})

	conceal.apply_buffer_conceal(buf)
end

--- :SmartPreview —— 智能预览 TODO/代码
function M.smart_preview()
	require("todo2.handlers").preview_content()
end

--- :TodoDoctor —— 只读体检：主库与归档冷库同 id 的冲突（归档后文件行被写回复活的副本）
function M.doctor()
	local ok_archive, archive = pcall(require, "todo2.store.archive")
	if not ok_archive then
		vim.notify("todo2: 归档模块不可用", vim.log.levels.ERROR)
		return
	end

	local ok, conflicts = pcall(archive.find_conflicts)
	if not ok then
		vim.notify("todo2 doctor: " .. tostring(conflicts), vim.log.levels.ERROR)
		return
	end

	if not conflicts or #conflicts == 0 then
		vim.notify("todo2 doctor: 未发现主库/冷库同 id 冲突 ✅", vim.log.levels.INFO)
		return
	end

	local entries = {}
	for _, c in ipairs(conflicts) do
		entries[#entries + 1] = {
			filename = c.file,
			lnum = c.line or 1,
			text = string.format(
				"%s 已在归档库（main=%s, archived_at=%s%s）",
				c.id,
				tostring(c.main_status),
				c.archived_at and os.date("%Y-%m-%d %H:%M", c.archived_at) or "?",
				c.in_cold and "" or ", 冷库缺失"
			),
		}
	end
	vim.fn.setqflist({}, "r", { title = "todo2 doctor: archived-id conflicts", items = entries })
	vim.cmd("copen")
	vim.notify(
		string.format("todo2 doctor: %d 个主库/冷库同 id 冲突（见 quickfix）", #conflicts),
		vim.log.levels.WARN
	)
end

return M
