-- lua/todo2/core/events.lua
--- @module todo2.core.events
--- @brief 改进版事件系统（修复自动保存事件处理）

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

	-- ⭐ 修复：添加时间戳，防止相同的事件被错误阻止
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
-- ⭐ 新增：从代码文件中提取引用的 TODO IDs
---------------------------------------------------------------------
local function extract_todo_ids_from_code_file(path)
	local todo_ids = {}

	-- 尝试读取文件
	local success, lines = pcall(vim.fn.readfile, path)
	if not success or not lines then
		return todo_ids
	end

	-- 从代码文件中提取 TODO 引用
	for _, line in ipairs(lines) do
		local tag, id = line:match("(%u+):ref:(%w+)")
		if id then
			todo_ids[id] = true
		end
	end

	return vim.tbl_keys(todo_ids)
end

---------------------------------------------------------------------
-- 合并事件并触发刷新（修复版）
---------------------------------------------------------------------
-- 事件处理函数（修复版）
local function process_events(events)
	if #events == 0 then
		return
	end

	-- 合并和去重
	local merged_events = merge_events(events)

	if #merged_events == 0 then
		return
	end

	-- 获取模块
	local store_mod = module.get("store")
	local parser_mod = module.get("core.parser")
	local ui_mod = module.get("ui")
	local renderer_mod = module.get("link.renderer")

	-- ⭐ 修复：第一阶段扩展：收集所有受影响的文件
	local affected_files = {}
	local code_file_to_todo_ids = {} -- 代码文件 -> [todo_ids]
	local todo_file_to_code_files = {} -- todo文件 -> [code_files]

	for _, item in ipairs(merged_events) do
		local ev = item.ev

		-- 1. 直接受影响文件
		if ev.file then
			local path = vim.fn.fnamemodify(ev.file, ":p")
			affected_files[path] = true

			-- 如果是代码文件，提取引用的 TODO IDs
			if not path:match("%.todo%.md$") then
				local todo_ids = extract_todo_ids_from_code_file(path)
				if #todo_ids > 0 then
					code_file_to_todo_ids[path] = todo_ids
				end
			end
		end

		-- 2. 通过 IDs 找到相关文件
		if ev.ids then
			for _, id in ipairs(ev.ids) do
				-- 获取 TODO 链接
				local todo_link = store_mod.get_todo_link(id)
				if todo_link then
					affected_files[todo_link.path] = true

					-- 记录 todo 文件关联的代码文件
					if ev.file and not ev.file:match("%.todo%.md$") then
						todo_file_to_code_files[todo_link.path] = todo_file_to_code_files[todo_link.path] or {}
						table.insert(todo_file_to_code_files[todo_link.path], ev.file)
					end
				end

				-- 获取代码链接
				local code_link = store_mod.get_code_link(id)
				if code_link then
					affected_files[code_link.path] = true
				end
			end
		end
	end

	-- ⭐ 修复：第二阶段：建立双向关联
	-- 从代码文件找到对应的 todo 文件
	for code_path, todo_ids in pairs(code_file_to_todo_ids) do
		for _, id in ipairs(todo_ids) do
			local todo_link = store_mod.get_todo_link(id)
			if todo_link then
				affected_files[todo_link.path] = true

				-- 记录关联关系
				todo_file_to_code_files[todo_link.path] = todo_file_to_code_files[todo_link.path] or {}
				if not vim.tbl_contains(todo_file_to_code_files[todo_link.path], code_path) then
					table.insert(todo_file_to_code_files[todo_link.path], code_path)
				end
			end
		end
	end

	-- 第三阶段：清理解析器缓存
	for path, _ in pairs(affected_files) do
		parser_mod.clear_cache(path)
	end

	-- ⭐ 新增：立即同步存储状态，修复双链一致性
	-- 这里在清理缓存后立即修复，确保存储状态正确
	for _, item in ipairs(merged_events) do
		local ev = item.ev
		if ev.ids then
			for _, id in ipairs(ev.ids) do
				-- 立即检查并修复双链状态
				local check = store_mod.check_link_consistency(id)
				if check and check.needs_repair then
					store_mod.repair_link_inconsistency(id, "latest")
					-- 修复后重新清理相关文件的缓存
					local todo_link = store_mod.get_todo_link(id)
					local code_link = store_mod.get_code_link(id)
					if todo_link then
						parser_mod.clear_cache(todo_link.path)
					end
					if code_link then
						parser_mod.clear_cache(code_link.path)
					end
				end
			end
		end
	end

	-- ⭐ 修复：第四阶段：对称刷新所有相关缓冲区
	local processed_buffers = {} -- 防止重复处理

	-- 处理函数：刷新缓冲区
	local function refresh_buffer(bufnr, path)
		if processed_buffers[bufnr] then
			return
		end
		processed_buffers[bufnr] = true

		-- ⭐ 检查buffer是否被修改，避免不必要的刷新
		if vim.api.nvim_buf_get_option(bufnr, "modified") then
			local success = pcall(vim.api.nvim_buf_call, bufnr, function()
				vim.cmd("silent write")
			end)

			if success then
				-- 保存后更新文件修改时间
				parser_mod.clear_cache(path)
			end
		end

		-- 对称刷新处理
		if path:match("%.todo%.md$") and ui_mod and ui_mod.refresh then
			ui_mod.refresh(bufnr, true) -- 强制重新解析
		else
			-- 对于代码文件，确保关联的 todo 文件已经重新解析
			local todo_files = todo_file_to_code_files[path] or {}
			for _, todo_path in ipairs(todo_files) do
				parser_mod.clear_cache(todo_path)
				local todo_bufnr = vim.fn.bufnr(todo_path)
				if todo_bufnr ~= -1 and vim.api.nvim_buf_is_valid(todo_bufnr) and ui_mod and ui_mod.refresh then
					ui_mod.refresh(todo_bufnr, true)
				end
			end

			-- 渲染代码文件
			if renderer_mod then
				if renderer_mod.invalidate_render_cache then
					renderer_mod.invalidate_render_cache(bufnr)
				end
				renderer_mod.render_code_status(bufnr)
			end
		end
	end

	-- 刷新所有受影响的缓冲区
	for path, _ in pairs(affected_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			refresh_buffer(bufnr, path)
		end
	end

	-- 清理活跃事件标记
	for _, item in ipairs(merged_events) do
		active_events[item.id] = nil
	end
end
---------------------------------------------------------------------
-- ⭐ 统一事件入口（修复版 - 修复自动保存事件处理）
---------------------------------------------------------------------
function M.on_state_changed(ev)
	ev = ev or {}
	ev.source = ev.source or "unknown"

	-- ⭐ 修复：精确匹配归档事件，避免自动保存事件被误判
	-- 只处理明确的归档事件，不处理包含"archive"子串的其他事件
	local archive_sources = {
		["archive"] = true,
		["archive_completed_tasks"] = true,
		["archive_module"] = true,
		-- 只添加明确的归档事件来源
	}

	if archive_sources[ev.source] then
		-- 归档事件：只清理缓存，不触发复杂的状态同步
		local parser_mod = module.get("core.parser")
		if ev.file and parser_mod then
			parser_mod.clear_cache(ev.file)
		end

		-- 如果有UI模块，刷新当前缓冲区
		local ui_mod = module.get("ui")
		if ui_mod and ev.bufnr and ev.bufnr > 0 then
			-- ⭐ 只刷新当前缓冲区，不触发双向刷新
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(ev.bufnr) then
					ui_mod.refresh(ev.bufnr, true) -- 强制重新解析
				end
			end)
		end
		return
	end

	-- 添加时间戳
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
-- ⭐ 新增：手动触发双向刷新
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
