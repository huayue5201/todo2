-- lua/todo2/core/events.lua
-- ⭐ 精简版：合并冗余函数，功能完全保留

local M = {}

---------------------------------------------------------------------
-- 直接依赖
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
		local event_id = generate_event_id(ev)
		if not active_events[event_id] then
			local source = ev.source or "unknown"
			if (event_depth[source] or 0) < MAX_EVENT_DEPTH and not seen[event_id] then
				seen[event_id] = true
				active_events[event_id] = true
				table.insert(merged, { ev = ev, id = event_id })
			end
		end
	end
	return merged
end

---------------------------------------------------------------------
-- ⭐ 合并函数：刷新缓冲区（合并了refresh_buffer和refresh_code_conceal）
---------------------------------------------------------------------
local function refresh_buffer_enhanced(bufnr, path, opts)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	-- 清理解析器缓存
	scheduler.invalidate_cache(path)

	-- 刷新渲染
	scheduler.refresh(bufnr, opts or { force_refresh = true })

	-- 如果是代码文件，触发额外事件（原refresh_code_conceal的逻辑）
	if not path:match("%.todo%.md$") then
		-- 检查是否有TODO标记
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

		-- 触发用户autocmd
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "Todo2CodeBufferChanged",
			data = { bufnr = bufnr, path = path },
		})
	end

	return true
end

---------------------------------------------------------------------
-- ⭐ 合并函数：收集受影响的文件和行号
---------------------------------------------------------------------
local function collect_affected_files_and_lines(events)
	local files = {} -- 文件路径 -> true
	local file_lines = {} -- 文件路径 -> {行号列表}
	local all_ids = {} -- ID -> true

	for _, item in ipairs(events) do
		local ev = item.ev

		-- 收集IDs
		if ev.ids then
			for _, id in ipairs(ev.ids) do
				all_ids[id] = true
			end
		end

		-- 从files字段收集
		if ev.files then
			for _, file in ipairs(ev.files) do
				files[vim.fn.fnamemodify(file, ":p")] = true
			end
		end

		-- 从file字段收集
		if ev.file then
			files[vim.fn.fnamemodify(ev.file, ":p")] = true
		end
	end

	-- 从IDs收集具体的行号
	local id_list = vim.tbl_keys(all_ids)
	if #id_list > 0 then
		for _, id in ipairs(id_list) do
			-- TODO文件中的行号
			local todo_link = link_mod.get_todo(id, { verify_line = true })
			if todo_link and todo_link.path then
				local path = vim.fn.fnamemodify(todo_link.path, ":p")
				files[path] = true
				if todo_link.line then
					file_lines[path] = file_lines[path] or {}
					table.insert(file_lines[path], todo_link.line)
				end
			end

			-- 代码文件中的行号
			local code_link = link_mod.get_code(id, { verify_line = true })
			if code_link and code_link.path then
				local path = vim.fn.fnamemodify(code_link.path, ":p")
				files[path] = true
				if code_link.line then
					file_lines[path] = file_lines[path] or {}
					table.insert(file_lines[path], code_link.line)
				end
			end
		end
	end

	-- 从代码文件提取关联的TODO文件
	local extra_files = {}
	for path, _ in pairs(files) do
		if not path:match("%.todo%.md$") then
			local todo_ids = {}
			local success, lines = pcall(vim.fn.readfile, path)
			if success and lines then
				for _, line in ipairs(lines) do
					if id_utils.contains_code_mark(line) then
						local id = id_utils.extract_id_from_code_mark(line)
						if id then
							todo_ids[id] = true
						end
					end
				end
			end

			for id, _ in pairs(todo_ids) do
				local todo_link = link_mod.get_todo(id, { verify_line = true })
				if todo_link and todo_link.path then
					extra_files[todo_link.path] = true
				end
			end
		end
	end

	-- 合并额外文件
	for path, _ in pairs(extra_files) do
		files[path] = true
	end

	return files, file_lines
end

---------------------------------------------------------------------
-- ⭐ 核心处理函数（合并了普通事件和批量事件的处理）
---------------------------------------------------------------------
local function process_events(events)
	if #events == 0 then
		return
	end

	local merged_events = merge_events(events)
	if #merged_events == 0 then
		return
	end

	-- 收集受影响的文件和行号
	local affected_files, file_lines = collect_affected_files_and_lines(merged_events)

	-- 清理解析器缓存
	for path, _ in pairs(affected_files) do
		scheduler.invalidate_cache(path)
	end

	-- 刷新所有受影响的缓冲区
	local processed = {}
	for path, _ in pairs(affected_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and not processed[bufnr] then
			processed[bufnr] = true

			local lines = file_lines[path]
			if lines and #lines > 0 then
				-- 去重行号
				local unique = {}
				local seen = {}
				for _, line in ipairs(lines) do
					if not seen[line] then
						seen[line] = true
						table.insert(unique, line)
					end
				end
				-- 增量刷新
				refresh_buffer_enhanced(bufnr, path, { from_event = true, lines = unique })
			else
				-- 全量刷新
				refresh_buffer_enhanced(bufnr, path, { from_event = true, force_refresh = true })
			end
		end
	end

	-- 清理活跃事件标记
	for _, item in ipairs(merged_events) do
		active_events[item.id] = nil
		local source = item.ev.source or "unknown"
		event_depth[source] = math.max(0, (event_depth[source] or 1) - 1)
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
		local code_link = link_mod.get_code(id, { verify_line = false })
		if code_link and code_link.path then
			files[code_link.path] = true
		end
		local todo_link = link_mod.get_todo(id, { verify_line = false })
		if todo_link and todo_link.path then
			files[todo_link.path] = true
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
-- 公共API
---------------------------------------------------------------------
function M.on_state_changed(ev)
	ev = ev or {}
	ev.source = ev.source or "unknown"
	ev.timestamp = os.time() * 1000
	ev = auto_complete_files(ev)

	local event_id = generate_event_id(ev)
	if active_events[event_id] then
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
