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

--- :TodoCalendar —— 月历视图（只读：带 @YYYY-MM-DD 的活跃任务）
---@param cmd_args table nvim 命令参数：args = "" | "YYYY-MM"
function M.calendar(cmd_args)
	local model = require("todo2.ui.calendar.model")
	local opts = {}
	local arg = vim.trim((cmd_args and cmd_args.args) or "")
	if arg ~= "" then
		local parsed = model.parse_month(arg)
		if not parsed then
			vim.notify(":TodoCalendar [YYYY-MM]", vim.log.levels.WARN)
			return
		end
		opts = parsed
	end
	require("todo2.ui.calendar").open(opts)
end

--- :TodoQuickfix —— 把当前上下文的任务固定到 quickfix（持久展示 + 原生跳转）。
--- 优先级：抽屉 / 日历浮窗 > 当前 TODO 文件 > 已打开的抽屉 > 已打开的日历。
function M.quickfix()
	local qf = require("todo2.task.quickfix")
	local drawer = require("todo2.ui.drawer")
	local buf = vim.api.nvim_get_current_buf()

	if drawer.is_drawer(buf) then
		drawer.quickfix()
		return
	end

	local calendar = require("todo2.ui.calendar")
	if vim.bo[buf].filetype == "todo2calendar" and calendar.quickfix() then
		return
	end

	local items, title = qf.buffer_items(buf)
	if items then
		qf.push(items, title)
		return
	end

	if drawer.is_open() then
		drawer.quickfix()
		return
	end
	if calendar.is_open() and calendar.quickfix() then
		return
	end

	vim.notify("todo2: open a TODO file, the drawer or the calendar first", vim.log.levels.WARN)
end

--- :TodoView preview —— 智能预览 TODO/代码
function M.smart_preview()
	require("todo2.handlers").preview_content()
end

--- :TodoSync! —— 全项目 TODO 文件全量对账（reindex，文件 = 真源）
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

--- :TodoGc —— 项目级回收：报告（! = 把超期的死项目目录移进隔离区）。
---@param apply boolean|nil 是否真的移动目录（:TodoGc!）
function M.gc(apply)
	local gc = require("todo2.store.project_gc")
	local result = gc.run({ apply = apply })
	local report = result.report

	local lines = {
		string.format(
			"todo2 gc: %d alive, %d gone, %d unknown, %d store-only",
			#report.alive,
			#report.gone,
			#report.unknown,
			#report.orphaned
		),
	}
	for _, entry in ipairs(result.kept) do
		lines[#lines + 1] = string.format("  keep     %s (last active %s)", entry.name, os.date("%Y-%m-%d", entry.last_active))
	end
	for _, target in ipairs(result.moved) do
		lines[#lines + 1] = string.format("  %s %s", apply and "moved to " or "would move to ", target)
	end
	local function append(list, label, field, suffix, limit)
		for i, item in ipairs(list) do
			if i > limit then
				lines[#lines + 1] = string.format("  … and %d more", #list - limit)
				break
			end
			lines[#lines + 1] = string.format("  %-8s %s %s", label, item[field], suffix)
		end
	end
	append(report.unknown, "unknown", "name", "(no .project.json)", 5)
	append(report.orphaned, "store", "root", "(no TODO directory)", 5)
	if not apply and #result.moved > 0 then
		lines[#lines + 1] = "run :TodoGc! to quarantine them (files are moved, never deleted)"
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
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

	local gc_summary = require("todo2.store.project_gc").summary()
	vim.notify("todo2 doctor: " .. orphan_msg .. "\n" .. gc_summary, vim.log.levels.INFO)
end

--- :TodoProfile —— 打印插桩耗时（! = 清空累计）。
---@param reset boolean|nil 是否清空累计（:TodoProfile!）
function M.profile(reset)
	local profiler = require("todo2.utils.profiler")
	if reset then
		profiler.reset()
		vim.notify("todo2 profile: cleared", vim.log.levels.INFO)
		return
	end

	local lines = profiler.report()
	if #lines == 0 then
		local hint = profiler.enabled() and "no samples yet" or "set profile.enabled = true to collect"
		vim.notify("todo2 profile: " .. hint, vim.log.levels.INFO)
		return
	end
	vim.notify("todo2 profile:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
