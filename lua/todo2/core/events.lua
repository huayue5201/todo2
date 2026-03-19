-- lua/todo2/core/events.lua
-- 事件模块：负责收集事件并触发渲染（TODO + CODE）

local M = {}

local scheduler = require("todo2.render.scheduler")
local core = require("todo2.store.link.core")

---------------------------------------------------------------------
-- 防抖队列
---------------------------------------------------------------------
local pending = {}
local timer = nil
local DEBOUNCE = 30

---------------------------------------------------------------------
-- 获取任务关联的文件（TODO + CODE）
---------------------------------------------------------------------
local function collect_related_files(ids)
	local files = {} -- path -> { ids = {} }

	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task then
			-- TODO 文件
			if task.locations.todo and task.locations.todo.path then
				local p = task.locations.todo.path
				files[p] = files[p] or { ids = {} }
				files[p].ids[id] = true
			end

			-- CODE 文件
			if task.locations.code and task.locations.code.path then
				local p = task.locations.code.path
				files[p] = files[p] or { ids = {} }
				files[p].ids[id] = true
			end
		end
	end

	return files
end

---------------------------------------------------------------------
-- 合并事件：统一收集所有文件 + 所有 ID
---------------------------------------------------------------------
local function merge_events(events)
	local result = {} -- path -> { ids = {} }

	for _, ev in ipairs(events) do
		local ids = ev.changed_ids or ev.ids or {}

		-- 1) ev.file
		if ev.file then
			result[ev.file] = result[ev.file] or { ids = {} }
			for _, id in ipairs(ids) do
				result[ev.file].ids[id] = true
			end
		end

		-- 2) ev.files
		if ev.files then
			for _, f in ipairs(ev.files) do
				result[f] = result[f] or { ids = {} }
				for _, id in ipairs(ids) do
					result[f].ids[id] = true
				end
			end
		end

		-- 3) 关联文件（另一端）
		if #ids > 0 then
			local related = collect_related_files(ids)
			for path, data in pairs(related) do
				result[path] = result[path] or { ids = {} }
				for id in pairs(data.ids) do
					result[path].ids[id] = true
				end
			end
		end
	end

	return result
end

---------------------------------------------------------------------
-- 事件入口
---------------------------------------------------------------------
function M.on_state_changed(ev)
	ev = ev or {}
	ev.timestamp = os.time() * 1000

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

---------------------------------------------------------------------
-- 事件处理（统一刷新）
---------------------------------------------------------------------
function M._process(events)
	if #events == 0 then
		return
	end

	-- 统一合并所有事件
	local all_files = merge_events(events)

	-- ⭐ 收集所有删除的位置信息
	local all_deleted_locations = {}
	for _, ev in ipairs(events) do
		if ev.deleted_locations then
			for _, loc in ipairs(ev.deleted_locations) do
				table.insert(all_deleted_locations, loc)
			end
		end
	end

	-- 刷新所有文件
	for path, data in pairs(all_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			-- 收集 ID 列表
			local ids = {}
			for id in pairs(data.ids) do
				table.insert(ids, id)
			end

			-- 调试输出
			if vim.g.todo_debug then
				vim.notify(
					string.format("事件刷新: %s, IDs: %d, 删除位置: %d", path, #ids, #all_deleted_locations),
					vim.log.levels.DEBUG
				)
			end

			-- 强制刷新缓存
			scheduler.invalidate_cache(path)

			-- 增量 or 全量（传递删除位置）
			scheduler.refresh(bufnr, {
				force_refresh = true,
				changed_ids = (#ids > 0) and ids or nil,
				deleted_locations = all_deleted_locations, -- ⭐ 传递
			})
		end
	end
end
return M
