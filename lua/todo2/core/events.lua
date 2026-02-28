-- lua/todo2/core/events.lua
--- @module todo2.core.events
--- @brief 改进版事件系统（支持防循环和批量事件）

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local link_mod = require("todo2.store.link")
local parser = require("todo2.core.parser")
local conceal = require("todo2.render.conceal")
local scheduler = require("todo2.render.scheduler")
local id_utils = require("todo2.utils.id") -- 新增依赖

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local pending_events = {}
local active_events = {}
local timer = nil
local DEBOUNCE = 50

-- 防循环机制
local MAX_EVENT_DEPTH = 5
local event_depth = {}

-- 生成事件唯一标识
local function generate_event_id(ev)
	if not ev then
		return "unknown"
	end

	local parts = {}
	table.insert(parts, ev.source or "unknown")

	if ev.file then
		local path = vim.fn.fnamemodify(ev.file, ":p")
		table.insert(parts, path)
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

		if active_events[event_id] then
			goto continue
		end

		local source = ev.source or "unknown"
		local depth = event_depth[source] or 0
		if depth >= MAX_EVENT_DEPTH then
			vim.notify(
				string.format("检测到事件循环深度 %d，跳过事件: %s", depth + 1, source),
				vim.log.levels.WARN
			)
			goto continue
		end

		if not seen[event_id] then
			seen[event_id] = true
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
-- ⭐ 修改：从代码文件中提取引用的 TODO IDs（使用 id_utils）
---------------------------------------------------------------------
local function extract_todo_ids_from_code_file(path)
	local todo_ids = {}

	local success, lines = pcall(vim.fn.readfile, path)
	if not success or not lines then
		return todo_ids
	end

	for _, line in ipairs(lines) do
		-- ⭐ 使用 id_utils 提取代码标记中的ID
		if id_utils.contains_code_mark(line) then
			local id = id_utils.extract_id_from_code_mark(line)
			if id then
				todo_ids[id] = true
			end
		end
	end

	return vim.tbl_keys(todo_ids)
end

---------------------------------------------------------------------
-- ⭐ 修改：检查代码文件是否包含 TODO 标记（使用 id_utils）
---------------------------------------------------------------------
local function has_todo_marks(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for _, line in ipairs(lines) do
		if id_utils.contains_code_mark(line) then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------
-- 刷新代码文件的 conceal
---------------------------------------------------------------------
local function refresh_code_conceal(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	if not has_todo_marks(bufnr) then
		return false
	end

	local success, result = pcall(function()
		conceal.apply_buffer_conceal(bufnr)
		conceal.setup_window_conceal(bufnr)
		return true
	end)

	if not success then
		vim.notify("刷新代码文件 conceal 失败: " .. tostring(result), vim.log.levels.DEBUG)
		return false
	end

	return true
end

---------------------------------------------------------------------
-- 刷新单个缓冲区（使用调度器）
---------------------------------------------------------------------
local function refresh_buffer(bufnr, path, todo_file_to_code_files, processed_buffers)
	if processed_buffers[bufnr] then
		return
	end
	processed_buffers[bufnr] = true

	scheduler.invalidate_cache(path)
	scheduler.refresh(bufnr, { force_refresh = true })

	if not path:match("%.todo%.md$") then
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "Todo2CodeBufferChanged",
			data = {
				bufnr = bufnr,
				path = path,
			},
		})
	end
end

---------------------------------------------------------------------
-- ⭐ 新增：处理批量事件
---------------------------------------------------------------------
local function process_batch_event(ev)
	if not ev.ids or #ev.ids == 0 then
		return
	end

	-- 收集所有受影响的文件
	local files = {}

	-- 如果有直接提供的文件列表，优先使用
	if ev.files then
		for _, file in ipairs(ev.files) do
			files[file] = true
		end
	end

	-- 通过ID获取文件
	if not next(files) then
		for _, id in ipairs(ev.ids) do
			local todo_link = link_mod.get_todo(id, { verify_line = false })
			if todo_link and todo_link.path then
				files[todo_link.path] = true
			end

			local code_link = link_mod.get_code(id, { verify_line = false })
			if code_link and code_link.path then
				files[code_link.path] = true
			end
		end
	end

	-- 使所有相关文件的缓存失效
	for file, _ in pairs(files) do
		scheduler.invalidate_cache(file)
	end

	-- 刷新所有相关缓冲区
	for file, _ in pairs(files) do
		local bufnr = vim.fn.bufnr(file)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			scheduler.refresh(bufnr, { force_refresh = true })
		end
	end
end

---------------------------------------------------------------------
-- ⭐ 修改：合并事件并触发刷新（修复4 - 移除特殊处理）
---------------------------------------------------------------------
local function process_events(events)
	if #events == 0 then
		return
	end

	local merged_events = merge_events(events)

	if #merged_events == 0 then
		return
	end

	if not link_mod then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

	-- 检查是否有批量事件
	local has_batch = false
	for _, item in ipairs(merged_events) do
		if item.ev.source == "batch_state_change" then
			has_batch = true
			break
		end
	end

	-- 如果有批量事件，合并处理
	if has_batch then
		local all_ids = {}
		local all_files = {}

		for _, item in ipairs(merged_events) do
			if item.ev.source == "batch_state_change" then
				for _, id in ipairs(item.ev.ids or {}) do
					all_ids[id] = true
				end
				for _, file in ipairs(item.ev.files or {}) do
					all_files[file] = true
				end
			end
		end

		process_batch_event({
			ids = vim.tbl_keys(all_ids),
			files = vim.tbl_keys(all_files),
		})

		-- 清理活跃事件标记
		for _, item in ipairs(merged_events) do
			active_events[item.id] = nil
		end
		return
	end

	-- 第一阶段：收集所有受影响的文件（移除了特殊事件处理）
	local affected_files = {}
	local code_file_to_todo_ids = {}
	local todo_file_to_code_files = {}

	for _, item in ipairs(merged_events) do
		local ev = item.ev
		local source = ev.source or "unknown"

		event_depth[source] = (event_depth[source] or 0) + 1

		if ev.file then
			local path = vim.fn.fnamemodify(ev.file, ":p")
			affected_files[path] = true

			if not path:match("%.todo%.md$") then
				local todo_ids = extract_todo_ids_from_code_file(path)
				if #todo_ids > 0 then
					code_file_to_todo_ids[path] = todo_ids
				end
			end
		end

		if ev.ids then
			for _, id in ipairs(ev.ids) do
				local todo_link = link_mod.get_todo(id, { verify_line = true })
				if todo_link then
					affected_files[todo_link.path] = true

					if ev.file and not ev.file:match("%.todo%.md$") then
						todo_file_to_code_files[todo_link.path] = todo_file_to_code_files[todo_link.path] or {}
						table.insert(todo_file_to_code_files[todo_link.path], ev.file)
					end
				end

				local code_link = link_mod.get_code(id, { verify_line = true })
				if code_link then
					affected_files[code_link.path] = true
				end
			end
		end
	end

	-- 第二阶段：建立双向关联
	for code_path, todo_ids in pairs(code_file_to_todo_ids) do
		for _, id in ipairs(todo_ids) do
			local todo_link = link_mod.get_todo(id, { verify_line = true })
			if todo_link then
				affected_files[todo_link.path] = true
				todo_file_to_code_files[todo_link.path] = todo_file_to_code_files[todo_link.path] or {}
				if not vim.tbl_contains(todo_file_to_code_files[todo_link.path], code_path) then
					table.insert(todo_file_to_code_files[todo_link.path], code_path)
				end
			end
		end
	end

	-- 第三阶段：清理解析器缓存
	if parser then
		for path, _ in pairs(affected_files) do
			scheduler.invalidate_cache(path)
		end
	end

	-- 第四阶段：刷新缓冲区
	local processed_buffers = {}

	for path, _ in pairs(affected_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			refresh_buffer(bufnr, path, todo_file_to_code_files, processed_buffers)
		end
	end

	-- 清理活跃事件标记和深度计数
	for _, item in ipairs(merged_events) do
		active_events[item.id] = nil
		local source = item.ev.source or "unknown"
		event_depth[source] = math.max(0, (event_depth[source] or 1) - 1)
	end
end

---------------------------------------------------------------------
-- ⭐ 修改：统一事件入口（修复4 - 移除特殊处理）
---------------------------------------------------------------------
function M.on_state_changed(ev)
	ev = ev or {}
	ev.source = ev.source or "unknown"
	ev.timestamp = os.time() * 1000

	local event_id = generate_event_id(ev)
	if active_events[event_id] then
		return
	end

	-- ⭐ 移除 archive_sources 特殊处理，所有事件走统一流程

	-- 检查调用深度
	local depth = event_depth[ev.source] or 0
	if depth >= MAX_EVENT_DEPTH then
		vim.notify(
			string.format("达到最大事件深度 %d，丢弃事件: %s", MAX_EVENT_DEPTH, ev.source),
			vim.log.levels.WARN
		)
		return
	end

	-- 所有事件：正常走合并、去重流程
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
-- 工具函数
---------------------------------------------------------------------
function M.is_event_processing(ev)
	if not ev then
		return false
	end
	local event_id = generate_event_id(ev)
	return active_events[event_id] == true
end

return M
