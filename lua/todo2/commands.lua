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

--- :TodoReconcile —— 全项目 TODO 文件全量对账（reindex，文件 = 真源）
function M.reconcile()
	local result = require("todo2.core.reconcile").run()
	vim.notify(
		string.format(
			"🔄 Reconcile: %d file(s), %d added, %d removed, %d changed",
			result.files,
			result.added,
			result.removed,
			result.changed
		),
		vim.log.levels.INFO
	)
end

--- :TodoDoctor —— 体检：孤儿回收；带 ! 时强制执行。
---@param force boolean|nil 是否强制执行孤儿回收（:TodoDoctor!）
function M.doctor(force)
	-- 孤儿回收：仅 :TodoDoctor! 强制触发（常规启动时已在 setup 里自动跑）
	local orphan = require("todo2.store.orphan")
	local sweep
	if force then
		sweep = orphan.sweep({ force = true })
	end
	local orphan_count = orphan.count()

	local orphan_msg = string.format("isolated orphans: %d", orphan_count)
	if sweep then
		orphan_msg = string.format(
			"%s (sweep: +%d quarantined, %d restored, %d purged)",
			orphan_msg,
			sweep.quarantined,
			sweep.restored,
			sweep.purged
		)
	end

	vim.notify("todo2 doctor: " .. orphan_msg, vim.log.levels.INFO)
end

return M
