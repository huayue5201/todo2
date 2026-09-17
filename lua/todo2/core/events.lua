-- lua/todo2/core/events.lua
-- 事件模块：负责收集事件并触发渲染（TODO + CODE）

local M = {}

local scheduler = require("todo2.render.scheduler")
local core = require("todo2.store.link.core")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------

local DEBOUNCE = 30

local pending = {}
local timer = nil

---------------------------------------------------------------------
-- 私有函数
---------------------------------------------------------------------

---收集与给定任务 ID 关联的所有文件路径
---
---遍历每个任务 ID，从存储中获取对应的任务对象，
---并将其 TODO 位置与 CODE 位置的路径加入文件集合（自动去重）。
---@param ids table 任务 ID 列表（数组）
---@return table<string, boolean> files 关联的文件路径集合（路径为键，值为 true）
local function collect_related_files(ids)
	local files = {}

	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task then
			if task.locations.todo and task.locations.todo.path then
				files[task.locations.todo.path] = true
			end
			if task.locations.code and task.locations.code.path then
				files[task.locations.code.path] = true
			end
		end
	end

	return files
end

---合并事件批次，计算需要刷新的文件集合
---
---遍历所有事件，收集每个事件直接指定的文件（ev.file 与 ev.files），
---再根据事件的 changed_ids / ids 递归收集关联文件，
---最终返回去重后的文件路径集合。
---@param events table 事件列表（数组）
---@return table<string, boolean> files_to_refresh 需要刷新的文件路径集合（路径为键，值为 true）
local function merge_events(events)
	local files_to_refresh = {}

	for _, ev in ipairs(events) do
		local main_files = {}

		if ev.file then
			table.insert(main_files, ev.file)
		end

		if ev.files then
			for _, f in ipairs(ev.files) do
				table.insert(main_files, f)
			end
		end

		for _, file_path in ipairs(main_files) do
			files_to_refresh[file_path] = true
		end

		local ids = ev.changed_ids or ev.ids or {}
		if #ids > 0 then
			local related = collect_related_files(ids)
			for path in pairs(related) do
				files_to_refresh[path] = true
			end
		end
	end

	return files_to_refresh
end

---处理一批待处理事件（内部函数，供定时器回调调用）
---
---合并事件以确定需要刷新的文件，收集所有删除位置与变更的任务 ID，
---最后对每个有效的 buffer 调用 scheduler.refresh 触发重新渲染。
---@param events table 待处理的事件列表（数组）
local function process(events)
	if #events == 0 then
		return
	end

	local files_to_refresh = merge_events(events)

	local deleted_locations = {}
	for _, ev in ipairs(events) do
		if ev.deleted_locations then
			for _, loc in ipairs(ev.deleted_locations) do
				table.insert(deleted_locations, loc)
			end
		end
	end

	-- 收集所有变更的 ID
	local all_changed_ids = {}
	for _, ev in ipairs(events) do
		local ids = ev.changed_ids or ev.ids or {}
		for _, id in ipairs(ids) do
			all_changed_ids[id] = true
		end
	end
	local changed_ids = {}
	for id in pairs(all_changed_ids) do
		table.insert(changed_ids, id)
	end

	for path in pairs(files_to_refresh) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			scheduler.refresh(bufnr, {
				changed_ids = changed_ids,
				deleted_locations = deleted_locations,
			})
		end
	end
end
---------------------------------------------------------------------
-- 公共 API
---------------------------------------------------------------------

---状态变更事件入口（公共 API）
---
---接收单个状态变更事件，将其加入待处理队列，并通过防抖定时器
---延迟批量处理，避免频繁刷新。若已有定时器在运行，则先停止并关闭，
---再创建新的定时器，延迟 DEBOUNCE 毫秒后在主线程中批量调用 _process。
---@param events table 状态上下文（事件对象），需包含 file 或 files 字段
function M.on_state_changed(events)
	if not events or (not events.file and not events.files) then
		return
	end

	table.insert(pending, events)

	if timer then
		timer:stop()
		timer:close()
	end

	timer = vim.uv.new_timer()
	timer:start(DEBOUNCE, 0, function()
		vim.schedule(function()
			local batch = pending
			pending = {}
			process(batch)
		end)
	end)
end

return M
