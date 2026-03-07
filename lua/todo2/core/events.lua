-- lua/todo2/core/events.lua
-- ⭐ 最终版：按任务 ID 驱动的事件系统（唯一方案）

local M = {}

---------------------------------------------------------------------
-- 依赖
---------------------------------------------------------------------
local link_mod = require("todo2.store.link")
local parser = require("todo2.core.parser")
local conceal = require("todo2.render.conceal")
local scheduler = require("todo2.render.scheduler")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local pending_events = {}
local active_events = {}
local timer = nil
local DEBOUNCE = 50
local MAX_EVENT_DEPTH = 5
local event_depth = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
local function generate_event_id(ev)
	if not ev then
		return "unknown"
	end
	local parts = { ev.source or "unknown" }
	if ev.file then
		table.insert(parts, vim.fn.fnamemodify(ev.file, ":p"))
	end
	if ev.ids and #ev.ids > 0 then
		table.sort(ev.ids)
		table.insert(parts, table.concat(ev.ids, ","))
	end
	if ev.bufnr then
		table.insert(parts, "buf" .. tostring(ev.bufnr))
	end
	table.insert(parts, tostring(ev.timestamp or os.time() * 1000))
	return table.concat(parts, ":")
end

local function merge_events(events)
	if #events == 0 then
		return {}
	end
	local merged, seen = {}, {}
	for _, ev in ipairs(events) do
		local id = generate_event_id(ev)
		if not active_events[id] then
			local src = ev.source or "unknown"
			if (event_depth[src] or 0) < MAX_EVENT_DEPTH and not seen[id] then
				seen[id] = true
				active_events[id] = true
				table.insert(merged, { ev = ev, id = id })
			end
		end
	end
	return merged
end

---------------------------------------------------------------------
-- ⭐ 按任务 ID 收集受影响文件
---------------------------------------------------------------------
local function collect_affected_files_and_ids(events)
	local files = {} -- path → true
	local file_ids = {} -- path → { id1, id2, ... }
	local all_ids = {} -- id → true

	-- 收集所有事件中的 ids
	for _, item in ipairs(events) do
		local ev = item.ev
		if ev.ids then
			for _, id in ipairs(ev.ids) do
				all_ids[id] = true
			end
		end
		if ev.file then
			files[vim.fn.fnamemodify(ev.file, ":p")] = true
		end
		if ev.files then
			for _, f in ipairs(ev.files) do
				files[vim.fn.fnamemodify(f, ":p")] = true
			end
		end
	end

	-- 根据 ID 找到对应的 TODO 文件和 CODE 文件
	for id, _ in pairs(all_ids) do
		local todo = link_mod.get_todo(id, { verify_line = true })
		if todo and todo.path then
			local p = vim.fn.fnamemodify(todo.path, ":p")
			files[p] = true
			file_ids[p] = file_ids[p] or {}
			table.insert(file_ids[p], id)
		end

		local code = link_mod.get_code(id, { verify_line = true })
		if code and code.path then
			local p = vim.fn.fnamemodify(code.path, ":p")
			files[p] = true
			file_ids[p] = file_ids[p] or {}
			table.insert(file_ids[p], id)
		end
	end

	return files, file_ids
end

---------------------------------------------------------------------
-- ⭐ 刷新缓冲区（唯一方案：按任务 ID 或全量）
---------------------------------------------------------------------
local function refresh_buffer_enhanced(bufnr, path, opts)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	-- 解析缓存失效
	scheduler.invalidate_cache(path)

	-- 直接把 opts 传给 scheduler（可能包含 changed_ids 或 force_refresh）
	scheduler.refresh(bufnr, opts)

	-- 代码文件：额外 conceal
	if not path:match("%.todo%.md$") then
		local has_todo = false
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		for _, line in ipairs(lines) do
			if id_utils.contains_code_mark(line) then
				has_todo = true
				break
			end
		end

		if has_todo then
			pcall(conceal.apply_buffer_conceal, bufnr)
			pcall(conceal.setup_window_conceal, bufnr)
		end

		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "Todo2CodeBufferChanged",
			data = { bufnr = bufnr, path = path },
		})
	end

	return true
end

---------------------------------------------------------------------
-- ⭐ 核心事件处理（按任务 ID 增量）
---------------------------------------------------------------------
local function process_events(events)
	if #events == 0 then
		return
	end

	local merged = merge_events(events)
	if #merged == 0 then
		return
	end

	-- 收集受影响文件 + changed_ids
	local affected_files, file_ids = collect_affected_files_and_ids(merged)

	-- 刷新所有受影响的 buffer
	local processed = {}
	for path, _ in pairs(affected_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and not processed[bufnr] then
			processed[bufnr] = true

			local ids = file_ids[path]
			if ids and #ids > 0 then
				-- ⭐ 按任务 ID 增量渲染
				refresh_buffer_enhanced(bufnr, path, {
					from_event = true,
					changed_ids = ids,
				})
			else
				-- 无 ID → 全量
				refresh_buffer_enhanced(bufnr, path, {
					from_event = true,
					force_refresh = true,
				})
			end
		end
	end

	-- 清理活跃事件
	for _, item in ipairs(merged) do
		active_events[item.id] = nil
		local src = item.ev.source or "unknown"
		event_depth[src] = math.max(0, (event_depth[src] or 1) - 1)
	end
end

---------------------------------------------------------------------
-- 自动补全 files 字段（保持不变）
---------------------------------------------------------------------
local function auto_complete_files(ev)
	if ev.files and #ev.files > 0 then
		return ev
	end
	if not ev.ids or #ev.ids == 0 then
		if ev.file then
			ev.files = { ev.file }
		end
		return ev
	end

	local files = {}
	for _, id in ipairs(ev.ids) do
		local code = link_mod.get_code(id, { verify_line = false })
		if code and code.path then
			files[code.path] = true
		end
		local todo = link_mod.get_todo(id, { verify_line = false })
		if todo and todo.path then
			files[todo.path] = true
		end
	end

	if next(files) then
		ev.files = vim.tbl_keys(files)
	elseif ev.file then
		ev.files = { ev.file }
	end
	return ev
end

---------------------------------------------------------------------
-- ⭐ 公共 API：事件入口（唯一入口）
---------------------------------------------------------------------
function M.on_state_changed(ev)
	ev = ev or {}
	ev.source = ev.source or "unknown"
	ev.timestamp = os.time() * 1000
	ev = auto_complete_files(ev)

	local id = generate_event_id(ev)
	if active_events[id] then
		return
	end

	local depth = event_depth[ev.source] or 0
	if depth >= MAX_EVENT_DEPTH then
		vim.notify("达到最大事件深度，丢弃事件: " .. ev.source, vim.log.levels.WARN)
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

function M.is_event_processing(ev)
	if not ev then
		return false
	end
	return active_events[generate_event_id(ev)] == true
end

return M
