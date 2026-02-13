-- lua/todo2/core/events.lua
--- @module todo2.core.events
--- @brief 改进版事件系统（修复自动保存事件处理）

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local link_mod = require("todo2.store.link")
local parser = require("todo2.core.parser")
local ui = require("todo2.ui")
local renderer = require("todo2.link.renderer")
local consistency = require("todo2.store.consistency")
local conceal = require("todo2.ui.conceal")

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

		-- 跳过正在处理的事件（防止循环）
		if active_events[event_id] then
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
-- 从代码文件中提取引用的 TODO IDs
---------------------------------------------------------------------
local function extract_todo_ids_from_code_file(path)
	local todo_ids = {}

	local success, lines = pcall(vim.fn.readfile, path)
	if not success or not lines then
		return todo_ids
	end

	for _, line in ipairs(lines) do
		local tag, id = line:match("(%u+):ref:(%w+)")
		if id then
			todo_ids[id] = true
		end
	end

	return vim.tbl_keys(todo_ids)
end

---------------------------------------------------------------------
-- 刷新单个缓冲区（增强版）
---------------------------------------------------------------------
local function refresh_buffer(bufnr, path, todo_file_to_code_files, processed_buffers)
	if processed_buffers[bufnr] then
		return
	end
	processed_buffers[bufnr] = true

	if vim.api.nvim_buf_get_option(bufnr, "modified") then
		local success = pcall(vim.api.nvim_buf_call, bufnr, function()
			vim.cmd("silent write")
		end)

		if success and parser then
			parser.invalidate_cache(path)
		end
	end

	if path:match("%.todo%.md$") and ui and ui.refresh then
		ui.refresh(bufnr, true)
	else
		-- 优化：只刷新受影响的任务文件对应的代码缓冲区
		local todo_files = todo_file_to_code_files[path] or {}
		for _, todo_path in ipairs(todo_files) do
			if parser then
				parser.invalidate_cache(todo_path)
			end
			local todo_bufnr = vim.fn.bufnr(todo_path)
			if todo_bufnr ~= -1 and vim.api.nvim_buf_is_valid(todo_bufnr) and ui and ui.refresh then
				ui.refresh(todo_bufnr, true)
			end
		end

		-- 通过事件触发渲染，这样其他监听模块也能收到通知
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "Todo2CodeBufferChanged",
			data = {
				bufnr = bufnr,
				path = path,
			},
		})

		-- 同时保留直接渲染调用（作为主渲染器）
		if renderer then
			if renderer.invalidate_render_cache then
				renderer.invalidate_render_cache(bufnr)
			end
			if renderer.render_code_status then
				renderer.render_code_status(bufnr)
			end
		end
	end
end

---------------------------------------------------------------------
-- 合并事件并触发刷新（修复版）
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

	-- 第一阶段扩展：收集所有受影响的文件
	local affected_files = {}
	local code_file_to_todo_ids = {}
	local todo_file_to_code_files = {}

	for _, item in ipairs(merged_events) do
		local ev = item.ev

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
			parser.invalidate_cache(path)
		end
	end

	-- 立即同步存储状态，修复双链一致性
	for _, item in ipairs(merged_events) do
		local ev = item.ev
		if ev.ids then
			for _, id in ipairs(ev.ids) do
				if consistency then
					local check = consistency.check_link_pair_consistency(id)
					if check and check.needs_repair then
						consistency.repair_link_pair(id, "latest")
						local todo_link = link_mod.get_todo(id, { verify_line = true })
						local code_link = link_mod.get_code(id, { verify_line = true })
						if todo_link and parser then
							parser.invalidate_cache(todo_link.path)
						end
						if code_link and parser then
							parser.invalidate_cache(code_link.path)
						end
					end
				end
			end
		end
	end

	-- 第四阶段：刷新缓冲区（定义 processed_buffers 在这里）
	local processed_buffers = {}

	for path, _ in pairs(affected_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			refresh_buffer(bufnr, path, todo_file_to_code_files, processed_buffers)
		end
	end

	-- 清理活跃事件标记
	for _, item in ipairs(merged_events) do
		active_events[item.id] = nil
	end
end

---------------------------------------------------------------------
-- ⭐ 统一事件入口（增强归档分支）
---------------------------------------------------------------------
function M.on_state_changed(ev)
	ev = ev or {}
	ev.source = ev.source or "unknown"

	local archive_sources = {
		["archive"] = true,
		["archive_completed_tasks"] = true,
		["archive_module"] = true,
	}

	-- ⭐ 归档事件：特殊处理，不触发复杂的双向同步，仅刷新显示
	if archive_sources[ev.source] then
		if ev.file and parser then
			parser.invalidate_cache(ev.file)
		end

		-- 刷新当前缓冲区
		if ui and ev.bufnr and ev.bufnr > 0 then
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(ev.bufnr) then
					ui.refresh(ev.bufnr, true)
				end
			end)
		end

		-- 刷新所有已加载代码缓冲区的 conceal
		if conceal then
			vim.schedule(function()
				local bufs = vim.api.nvim_list_bufs()
				for _, buf in ipairs(bufs) do
					if vim.api.nvim_buf_is_loaded(buf) then
						local name = vim.api.nvim_buf_get_name(buf)
						if name and not name:match("%.todo%.md$") then
							conceal.apply_buffer_conceal(buf)
						end
					end
				end
			end)
		end

		return
	end

	-- 非归档事件：正常走合并、去重、双向同步流程
	ev.timestamp = os.time() * 1000
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

---------------------------------------------------------------------
-- 手动触发双向刷新
---------------------------------------------------------------------
function M.trigger_bidirectional_refresh(path)
	if not path then
		return
	end

	local full_path = vim.fn.fnamemodify(path, ":p")

	M.on_state_changed({
		source = "manual_refresh",
		file = full_path,
		timestamp = os.time() * 1000,
	})
end

return M
