-- lua/todo2/core/events.lua
-- 事件模块：负责收集事件并触发渲染

local M = {}

local scheduler = require("todo2.render.scheduler")
local core = require("todo2.store.link.core")

---------------------------------------------------------------------
-- 事件队列（防抖）
---------------------------------------------------------------------
local pending = {}
local timer = nil
local DEBOUNCE = 30

---------------------------------------------------------------------
-- 获取任务关联的所有文件（两端）
---------------------------------------------------------------------

---获取任务关联的文件路径
---@param ids string[] 任务ID列表
---@return table<string, table> 文件路径到ID列表的映射
local function get_related_files(ids)
	local files = {} -- path -> { ids = {} }

	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task then
			-- TODO 文件
			if task.locations.todo and task.locations.todo.path then
				if not files[task.locations.todo.path] then
					files[task.locations.todo.path] = { ids = {} }
				end
				files[task.locations.todo.path].ids[id] = true
			end

			-- CODE 文件
			if task.locations.code and task.locations.code.path then
				if not files[task.locations.code.path] then
					files[task.locations.code.path] = { ids = {} }
				end
				files[task.locations.code.path].ids[id] = true
			end
		end
	end

	return files
end

---------------------------------------------------------------------
-- 事件入口
---------------------------------------------------------------------

---状态变更事件入口
---@param ev { source?: string, file?: string, files?: string[], ids?: string[], changed_ids?: string[], timestamp?: number }
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
-- 事件处理：TODO + CODE 两端都刷新
---------------------------------------------------------------------

---处理事件批次
---@param events table[] 事件列表
function M._process(events)
	if #events == 0 then
		return
	end

	-- 收集所有受影响的文件和对应的 IDs
	local all_files = {} -- path -> { ids = {} }

	for _, ev in ipairs(events) do
		-- 处理单文件事件
		if ev.file then
			if not all_files[ev.file] then
				all_files[ev.file] = { ids = {} }
			end

			-- 收集 changed_ids
			local ids_to_add = ev.changed_ids or ev.ids or {}
			for _, id in ipairs(ids_to_add) do
				all_files[ev.file].ids[id] = true
			end
		end

		-- 处理多文件事件
		if ev.files then
			for _, f in ipairs(ev.files) do
				if not all_files[f] then
					all_files[f] = { ids = {} }
				end
				local ids_to_add = ev.changed_ids or ev.ids or {}
				for _, id in ipairs(ids_to_add) do
					all_files[f].ids[id] = true
				end
			end
		end

		-- 如果有 ids，获取关联的另一端文件
		local changed_ids = ev.changed_ids or ev.ids or {}
		if #changed_ids > 0 then
			local related = get_related_files(changed_ids)
			for path, data in pairs(related) do
				if not all_files[path] then
					all_files[path] = { ids = {} }
				end
				-- 合并 IDs
				for id in pairs(data.ids) do
					all_files[path].ids[id] = true
				end
			end
		end
	end

	-- 刷新每个文件
	for path, data in pairs(all_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			-- 收集所有 IDs
			local ids = {}
			for id in pairs(data.ids) do
				table.insert(ids, id)
			end

			-- ⭐ 调试输出
			if vim.g.todo_debug then
				vim.notify(string.format("事件刷新: %s, IDs: %d", path, #ids), vim.log.levels.DEBUG)
			end

			-- ⭐ 强制刷新缓存并渲染
			scheduler.invalidate_cache(path)

			-- 如果有changed_ids，使用增量渲染
			if #ids > 0 then
				scheduler.refresh(bufnr, {
					force_refresh = true,
					changed_ids = ids,
				})
			else
				-- 否则全量渲染
				scheduler.refresh(bufnr, {
					force_refresh = true,
				})
			end
		end
	end
end

return M
