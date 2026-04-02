-- lua/todo2/core/events.lua
-- 事件模块：负责收集事件并触发渲染（TODO + CODE）

---@module "todo2.core.events"
---@brief m
---
--- 事件系统核心模块，负责收集所有任务变更事件，
--- 进行防抖合并后统一触发 UI 刷新。
---
--- 主要功能：
--- - 事件防抖：避免频繁刷新
--- - 文件合并：将多个事件合并到同一文件的刷新
--- - 关联刷新：自动刷新关联的 TODO 和代码文件

local M = {}

local scheduler = require("todo2.render.scheduler")
local core = require("todo2.store.link.core")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------

---防抖延迟（毫秒）
local DEBOUNCE = 30

---事件队列
---@type table[]
local pending = {}

---防抖定时器
---@type uv_timer_t|nil
local timer = nil

---------------------------------------------------------------------
-- 私有函数
---------------------------------------------------------------------

---获取任务关联的文件（TODO + CODE）
---@param ids string[] 任务ID列表
---@return table<string, boolean> 文件路径集合
local function collect_related_files(ids)
	---@type table<string, boolean>
	local files = {}

	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task then
			-- TODO 文件
			if task.locations.todo and task.locations.todo.path then
				files[task.locations.todo.path] = true
			end
			-- CODE 文件
			if task.locations.code and task.locations.code.path then
				files[task.locations.code.path] = true
			end
		end
	end

	return files
end

---合并事件：收集需要刷新的文件
---@param events table[] 事件列表
---@return table<string, boolean> 需要刷新的文件路径集合
local function merge_events(events)
	---@type table<string, boolean>
	local files_to_refresh = {}

	for _, ev in ipairs(events) do
		-- 处理主文件
		---@type string[]
		local main_files = {}

		if ev.file then
			table.insert(main_files, ev.file)
		end

		if ev.files then
			for _, f in ipairs(ev.files) do
				table.insert(main_files, f)
			end
		end

		-- 添加主文件到刷新列表
		for _, file_path in ipairs(main_files) do
			files_to_refresh[file_path] = true
		end

		-- 处理关联文件（只有提供了 changed_ids 才需要）
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

---触发状态变更事件
---@param ev table 事件对象
---@param ev.source string 事件来源（如 "code_save", "todo_edit"）
---@param ev.file string|nil 主要文件路径
---@param ev.files string[]|nil 多个文件路径
---@param ev.bufnr number|nil 缓冲区号
---@param ev.changed_ids string[]|nil 变更的任务ID列表
---@param ev.ids string[]|nil 变更的任务ID列表（兼容旧接口）
---@param ev.deleted_locations table[]|nil 删除的位置信息
---@param ev.force_full_refresh boolean|nil 是否强制全量刷新（已废弃，保留兼容）
function M.on_state_changed(ev)
	-- 参数验证
	if not ev or (not ev.file and not ev.files) then
		return
	end

	-- 添加到队列
	table.insert(pending, ev)

	-- 重置定时器
	if timer then
		timer:stop()
		timer:close()
	end

	-- 启动新定时器
	timer = vim.loop.new_timer()
	timer:start(DEBOUNCE, 0, function()
		vim.schedule(function()
			local batch = pending
			pending = {}
			M._process(batch)
		end)
	end)
end

---处理事件队列（内部使用）
---@param events table[] 事件列表
function M._process(events)
	if #events == 0 then
		return
	end

	-- 收集需要刷新的文件
	local files_to_refresh = merge_events(events)

	-- 收集删除位置（如果有）
	---@type table[]
	local deleted_locations = {}
	for _, ev in ipairs(events) do
		if ev.deleted_locations then
			for _, loc in ipairs(ev.deleted_locations) do
				table.insert(deleted_locations, loc)
			end
		end
	end

	-- 刷新每个文件
	for path in pairs(files_to_refresh) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			-- 强制刷新缓存
			scheduler.invalidate_cache(path)

			-- 触发 UI 刷新
			scheduler.refresh(bufnr, {
				force_refresh = true,
				deleted_locations = deleted_locations,
			})
		end
	end
end

return M
