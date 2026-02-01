-- lua/todo2/core/events.lua
--- @module todo2.core.events
--- @brief 改进版事件系统（带去重和循环检测）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local pending_events = {}
local active_events = {} -- 正在处理的事件ID，用于检测循环
local timer = nil
local DEBOUNCE = 50

-- 生成事件唯一标识
local function generate_event_id(ev)
	if not ev then
		return "unknown"
	end

	local parts = {}

	-- 来源
	table.insert(parts, ev.source or "unknown")

	-- 文件（如果有）
	if ev.file then
		local path = vim.fn.fnamemodify(ev.file, ":p")
		table.insert(parts, path)
	end

	-- IDs（如果有）
	if ev.ids and #ev.ids > 0 then
		table.sort(ev.ids)
		table.insert(parts, table.concat(ev.ids, ","))
	end

	-- Buffer（如果有）
	if ev.bufnr then
		table.insert(parts, "buf" .. tostring(ev.bufnr))
	end

	return table.concat(parts, ":")
end

---------------------------------------------------------------------
-- 事件合并和去重
---------------------------------------------------------------------
local function merge_events(events)
	if #events == 0 then
		return {}
	end

	local merged = {}
	local seen = {}

	for _, ev in ipairs(events) do
		local event_id = generate_event_id(ev)

		-- 跳过正在处理的事件（防止循环）
		if active_events[event_id] then
			-- vim.notify("跳过循环事件: " .. event_id, vim.log.levels.WARN)
			goto continue
		end

		-- 去重：相同的事件ID只保留一个
		if not seen[event_id] then
			seen[event_id] = true

			-- 标记为活跃（防止在处理过程中再次被触发）
			active_events[event_id] = true

			table.insert(merged, {
				ev = ev,
				id = event_id,
			})
		end

		::continue::
	end

	return merged
end

---------------------------------------------------------------------
-- 合并事件并触发刷新（重构版）
---------------------------------------------------------------------
local function process_events(events)
	if #events == 0 then
		return
	end

	-- 合并和去重
	local merged_events = merge_events(events)

	if #merged_events == 0 then
		return
	end

	-- 第一阶段：收集所有受影响的文件
	local affected_files = {}
	local store_mod = module.get("store")

	for _, item in ipairs(merged_events) do
		local ev = item.ev

		if ev.file then
			local path = vim.fn.fnamemodify(ev.file, ":p")
			affected_files[path] = true
		end

		if ev.ids then
			for _, id in ipairs(ev.ids) do
				local todo = store_mod.get_todo_link(id)
				if todo then
					affected_files[todo.path] = true
				end

				local code = store_mod.get_code_link(id)
				if code then
					affected_files[code.path] = true
				end
			end
		end
	end

	-- 第二阶段：清理解析器缓存
	local parser_mod = module.get("core.parser")
	for path, _ in pairs(affected_files) do
		parser_mod.clear_cache(path)
	end

	-- 第三阶段：刷新相关buffer（但不触发新事件）
	local ui_mod = module.get("ui")
	local renderer_mod = module.get("link.renderer")

	for path, _ in pairs(affected_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			-- ⭐ 检查buffer是否被修改，避免不必要的刷新
			if vim.api.nvim_buf_get_option(bufnr, "modified") then
				-- 如果有修改，先保存（但不触发事件）
				local success = pcall(vim.api.nvim_buf_call, bufnr, function()
					vim.cmd("silent write")
				end)

				if success then
					-- 保存后更新文件修改时间
					parser_mod.clear_cache(path)
				end
			end

			if path:match("%.todo%.md$") and ui_mod and ui_mod.refresh then
				ui_mod.refresh(bufnr, true)
			elseif renderer_mod and renderer_mod.render_code_status then
				if renderer_mod.invalidate_render_cache then
					renderer_mod.invalidate_render_cache(bufnr)
				end
				renderer_mod.render_code_status(bufnr)
			end
		end
	end

	-- 清理活跃事件标记
	for _, item in ipairs(merged_events) do
		active_events[item.id] = nil
	end
end

---------------------------------------------------------------------
-- ⭐ 统一事件入口（改进版）
---------------------------------------------------------------------
function M.on_state_changed(ev)
	ev = ev or {}
	ev.source = ev.source or "unknown"

	-- 跳过来自autosave的事件（防止循环）
	if ev.source == "autosave" then
		return
	end

	table.insert(pending_events, ev)

	if timer then
		timer:stop()
		timer:close()
	end

	timer = vim.loop.new_timer()
	timer:start(DEBOUNCE, 0, function()
		vim.schedule(function()
			local batch = pending_events
			pending_events = {}
			process_events(batch)
		end)
	end)
end

---------------------------------------------------------------------
-- 工具函数：检查事件是否在处理中
---------------------------------------------------------------------
function M.is_event_processing(ev)
	if not ev then
		return false
	end
	local event_id = generate_event_id(ev)
	return active_events[event_id] == true
end

return M
