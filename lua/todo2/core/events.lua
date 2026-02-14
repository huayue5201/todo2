-- lua/todo2/core/events.lua
--- @module todo2.core.events
--- @brief 改进版事件系统（支持防循环）

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
-- NOTE:ref:050da4
local link_mod = require("todo2.store.link")
local parser = require("todo2.core.parser")
local ui = require("todo2.ui")
local renderer = require("todo2.link.renderer")
local conceal = require("todo2.ui.conceal")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local pending_events = {}
local active_events = {} -- 正在处理的事件ID，用于检测循环
local timer = nil
local DEBOUNCE = 50

-- ⭐ 防循环机制
local MAX_EVENT_DEPTH = 5
local event_depth = {} -- 记录每个来源的调用深度

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

		-- ⭐ 跳过正在处理的事件（防止循环）
		if active_events[event_id] then
			goto continue
		end

		-- ⭐ 检查调用深度
		local source = ev.source or "unknown"
		local depth = event_depth[source] or 0
		if depth >= MAX_EVENT_DEPTH then
			-- 超过深度限制，记录警告并跳过
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
-- 刷新单个缓冲区
---------------------------------------------------------------------
local function refresh_buffer(bufnr, path, todo_file_to_code_files, processed_buffers)
	if processed_buffers[bufnr] then
		return
	end
	processed_buffers[bufnr] = true

	if parser then
		parser.invalidate_cache(path)
	end

	if path:match("%.todo%.md$") and ui and ui.refresh then
		ui.refresh(bufnr, true)
	else
		-- 刷新受影响的任务文件
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

		-- 触发渲染
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "Todo2CodeBufferChanged",
			data = {
				bufnr = bufnr,
				path = path,
			},
		})

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
-- 处理待恢复的活跃状态
---------------------------------------------------------------------
local function handle_pending_restore(ev)
	if not ev.ids or #ev.ids == 0 or not ev.pending_status then
		return
	end

	local id = ev.ids[1]
	local target_status = ev.pending_status

	-- 检查当前状态
	local todo_link = link_mod.get_todo(id, { verify_line = true })
	if not todo_link then
		return
	end

	-- 只有从 COMPLETED 才能转换到活跃状态
	if todo_link.status ~= types.STATUS.COMPLETED then
		return
	end

	-- 验证目标状态是否合法
	if not types.is_active_status(target_status) then
		return
	end

	-- 执行状态转换
	local core_status = require("todo2.core.status")
	local success = core_status.update_active_status(id, target_status, "unarchive_complete")

	if success then
		-- 清除待恢复标记
		todo_link.pending_restore_status = nil

		if link_mod.update_todo then
			link_mod.update_todo(id, todo_link)
		else
			-- 如果 update_todo 不存在，直接存储
			local store = require("todo2.store.nvim_store")
			store.set_key("todo.links.todo." .. id, todo_link)
		end

		vim.schedule(function()
			local status_display = {
				[types.STATUS.URGENT] = "❗ 紧急",
				[types.STATUS.WAITING] = "❓ 等待",
				[types.STATUS.NORMAL] = "◻ 正常",
			}
			vim.notify(
				string.format(
					"任务 %s 已恢复为活跃状态: %s",
					id:sub(1, 6),
					status_display[target_status] or target_status
				),
				vim.log.levels.INFO
			)
		end)

		-- 触发刷新事件
		M.on_state_changed({
			source = "restore_complete",
			ids = { id },
			file = todo_link.path,
			bufnr = ev.bufnr,
			timestamp = os.time() * 1000,
		})
	end
end

---------------------------------------------------------------------
-- 合并事件并触发刷新
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

	-- 第一阶段：处理特殊事件（如待恢复状态）
	for _, item in ipairs(merged_events) do
		local ev = item.ev
		local source = ev.source or "unknown"

		-- ⭐ 增加调用深度
		event_depth[source] = (event_depth[source] or 0) + 1

		-- 处理待恢复状态
		if ev.source == "unarchive_pending" then
			handle_pending_restore(ev)
		end
	end

	-- 第二阶段：收集所有受影响的文件
	local affected_files = {}
	local code_file_to_todo_ids = {}
	local todo_file_to_code_files = {}

	for _, item in ipairs(merged_events) do
		local ev = item.ev

		-- 跳过已处理的事件类型
		if ev.source == "unarchive_pending" or ev.source == "restore_complete" then
			goto continue
		end

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

		::continue::
	end

	-- 第三阶段：建立双向关联
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

	-- 第四阶段：清理解析器缓存
	if parser then
		for path, _ in pairs(affected_files) do
			parser.invalidate_cache(path)
		end
	end

	-- 第五阶段：刷新缓冲区
	local processed_buffers = {}

	for path, _ in pairs(affected_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			refresh_buffer(bufnr, path, todo_file_to_code_files, processed_buffers)
		end
	end

	-- ⭐ 清理活跃事件标记和深度计数
	for _, item in ipairs(merged_events) do
		active_events[item.id] = nil
		local source = item.ev.source or "unknown"
		event_depth[source] = math.max(0, (event_depth[source] or 1) - 1)
	end
end

---------------------------------------------------------------------
-- ⭐ 统一事件入口（增强归档事件处理）
---------------------------------------------------------------------
function M.on_state_changed(ev)
	ev = ev or {}
	ev.source = ev.source or "unknown"
	ev.timestamp = os.time() * 1000

	-- 检查是否已经在处理相同的事件
	local event_id = generate_event_id(ev)
	if active_events[event_id] then
		return
	end

	-- ⭐ 归档事件来源列表
	local archive_sources = {
		["archive"] = true,
		["archive_completed_tasks"] = true,
		["archive_module"] = true,
		["unarchive_complete"] = true,
		["unarchive_pending"] = true,
	}

	-- ⭐ 归档事件：需要完整刷新UI，但不触发复杂的双向同步
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

		-- 如果有IDs，刷新所有相关缓冲区
		if ev.ids and #ev.ids > 0 then
			vim.schedule(function()
				for _, id in ipairs(ev.ids) do
					-- 刷新代码文件
					local code_link = link_mod.get_code(id, { verify_line = false })
					if code_link and code_link.path then
						local bufnr = vim.fn.bufnr(code_link.path)
						if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
							parser.invalidate_cache(code_link.path)
							if renderer then
								renderer.render_code_status(bufnr)
							end
						end
					end

					-- 刷新TODO文件
					local todo_link = link_mod.get_todo(id, { verify_line = false })
					if todo_link and todo_link.path then
						local bufnr = vim.fn.bufnr(todo_link.path)
						if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and ui and ui.refresh then
							ui.refresh(bufnr, true)
						end
					end
				end
			end)
		end

		-- 刷新所有代码缓冲区的 conceal
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

	-- 检查调用深度
	local depth = event_depth[ev.source] or 0
	if depth >= MAX_EVENT_DEPTH then
		vim.notify(
			string.format("达到最大事件深度 %d，丢弃事件: %s", MAX_EVENT_DEPTH, ev.source),
			vim.log.levels.WARN
		)
		return
	end

	-- 非归档事件：正常走合并、去重、双向同步流程
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
