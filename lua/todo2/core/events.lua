-- lua/todo2/core/events.lua
-- 事件模块：负责收集事件并触发渲染（TODO + CODE）
-- 修改版：移除 scheduler.invalidate_cache 调用

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

---------------------------------------------------------------------
-- 公共 API
---------------------------------------------------------------------

function M.on_state_changed(ev)
	if not ev or (not ev.file and not ev.files) then
		return
	end

	table.insert(pending, ev)

	if timer then
		timer:stop()
		timer:close()
	end

	timer = vim.loop.new_timer()
	timer:start(DEBOUNCE, 0, function()
		vim.schedule(function()
			local batch = pending
			pending = {}
			M._process(batch)
		end)
	end)
end

function M._process(events)
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
			-- 直接刷新，不再需要 invalidate_cache
			scheduler.refresh(bufnr, {
				changed_ids = changed_ids,
				deleted_locations = deleted_locations,
			})
		end
	end
end

return M
