-- lua/todo2/core/events.lua
-- ⭐ 最终版：snapshot-first + changed_ids + 无闪烁事件系统

local M = {}

local link_mod = require("todo2.store.link")
local conceal = require("todo2.render.conceal")
local scheduler = require("todo2.render.scheduler")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 事件状态
---------------------------------------------------------------------
local pending_events = {}
local active_events = {}
local timer = nil
local DEBOUNCE = 50
local MAX_EVENT_DEPTH = 5
local event_depth = {}

---------------------------------------------------------------------
-- 事件 ID（用于去重）
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

---------------------------------------------------------------------
-- 合并事件（去重 + 深度限制）
---------------------------------------------------------------------
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
-- 收集受影响文件 + ID
---------------------------------------------------------------------
local function collect_affected_files_and_ids(events)
	local files = {}
	local file_ids = {}
	local all_ids = {}

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

	for id, _ in pairs(all_ids) do
		local todo = link_mod.get_todo(id)
		if todo and todo.path then
			local p = vim.fn.fnamemodify(todo.path, ":p")
			files[p] = true
			file_ids[p] = file_ids[p] or {}
			table.insert(file_ids[p], id)
		end

		local code = link_mod.get_code(id)
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
-- ⭐ 刷新 buffer（snapshot-first + 无闪烁）
---------------------------------------------------------------------
local function refresh_buffer_enhanced(bufnr, path, opts)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	-- ⭐ invalidate 所有受影响文件（snapshot-first）
	if opts.files and #opts.files > 0 then
		for _, f in ipairs(opts.files) do
			scheduler.invalidate_cache(f)
		end
	else
		scheduler.invalidate_cache(path)
	end

	-- ⭐ TODO 文件：避免 force_refresh（否则闪烁）
	if path:match("%.todo%.md$") then
		opts.force_refresh = false
	end

	scheduler.refresh(bufnr, opts)

	-- ⭐ CODE 文件：增量 conceal
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
			pcall(conceal.apply_smart_conceal, bufnr)
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
-- ⭐ 核心事件处理（snapshot-first）
---------------------------------------------------------------------
local function process_events(events)
	if #events == 0 then
		return
	end

	local merged = merge_events(events)
	if #merged == 0 then
		return
	end

	local affected_files, file_ids = collect_affected_files_and_ids(merged)

	local processed = {}
	for path, _ in pairs(affected_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and not processed[bufnr] then
			processed[bufnr] = true

			local ids = file_ids[path]

			-- ⭐ changed_ids → 增量渲染（避免闪烁）
			if ids and #ids > 0 then
				refresh_buffer_enhanced(bufnr, path, {
					from_event = true,
					changed_ids = ids,
					files = vim.tbl_keys(affected_files),
				})
			else
				-- ⭐ TODO 文件不 force_refresh（避免闪烁）
				if path:match("%.todo%.md$") then
					refresh_buffer_enhanced(bufnr, path, {
						from_event = true,
						changed_ids = {},
						files = vim.tbl_keys(affected_files),
					})
				else
					refresh_buffer_enhanced(bufnr, path, {
						from_event = true,
						force_refresh = true,
						files = vim.tbl_keys(affected_files),
					})
				end
			end
		end
	end

	-- 清理 active 状态
	for _, item in ipairs(merged) do
		active_events[item.id] = nil
		local src = item.ev.source or "unknown"
		event_depth[src] = math.max(0, (event_depth[src] or 1) - 1)
	end
end

---------------------------------------------------------------------
-- 自动补全 files
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
		local code = link_mod.get_code(id)
		if code and code.path then
			files[code.path] = true
		end
		local todo = link_mod.get_todo(id)
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
-- ⭐ 公共 API：事件入口（snapshot-first）
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
