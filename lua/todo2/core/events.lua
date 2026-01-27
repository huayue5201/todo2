-- lua/todo2/core/events.lua
--- @module todo2.core.events
-- 专业级事件系统：统一刷新入口 + 防抖 + 精准刷新

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------

-- 待处理事件（批量合并）
local pending_events = {}

-- 防抖 timer
local timer = nil

-- 延迟（毫秒）
local DEBOUNCE = 50

---------------------------------------------------------------------
-- 工具：合并事件
---------------------------------------------------------------------

local function merge_events(events)
	local affected_ids = {}
	local affected_todo_files = {}
	local affected_code_files = {}

	local store_mod = module.get("store")

	for _, ev in ipairs(events) do
		-- 合并 ID
		if ev.ids then
			for _, id in ipairs(ev.ids) do
				affected_ids[id] = true
			end
		end

		-- 合并文件
		if ev.file then
			local path = vim.fn.fnamemodify(ev.file, ":p")

			if path:match("%.todo%.md$") then
				affected_todo_files[path] = true
			else
				affected_code_files[path] = true
			end
		end
	end

	-----------------------------------------------------------------
	-- 根据 ID 反查所有受影响的文件（TODO + CODE）
	-----------------------------------------------------------------
	for id, _ in pairs(affected_ids) do
		local todo = store_mod.get_todo_link(id)
		if todo then
			affected_todo_files[todo.path] = true
		end

		local code = store_mod.get_code_link(id)
		if code then
			affected_code_files[code.path] = true
		end
	end

	return affected_ids, affected_todo_files, affected_code_files
end

---------------------------------------------------------------------
-- 工具：找到所有 buffer（TODO / CODE）
---------------------------------------------------------------------

local function find_buffers_by_paths(paths)
	local bufs = {}

	for path, _ in pairs(paths) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			bufs[bufnr] = true
		end
	end

	return bufs
end

---------------------------------------------------------------------
-- ⭐ 核心刷新管线（专业级）
---------------------------------------------------------------------

function M.run_refresh_pipeline(events)
	if #events == 0 then
		return
	end

	-----------------------------------------------------------------
	-- 1. 合并事件
	-----------------------------------------------------------------
	local affected_ids, todo_files, code_files = merge_events(events)

	-----------------------------------------------------------------
	-- 2. 重新解析所有受影响的 TODO 文件（更新 parser 缓存）
	-----------------------------------------------------------------
	local parser_mod = module.get("core.parser")
	for path, _ in pairs(todo_files) do
		parser_mod.parse_file(path)
	end

	-----------------------------------------------------------------
	-- 3. 刷新 TODO buffer（精准刷新）
	-----------------------------------------------------------------
	local ui_mod = module.get("ui")
	local todo_bufs = find_buffers_by_paths(todo_files)
	for bufnr, _ in pairs(todo_bufs) do
		if ui_mod and ui_mod.refresh then
			ui_mod.refresh(bufnr)
		end
	end

	-----------------------------------------------------------------
	-- 4. 刷新代码 buffer（精准刷新）
	-----------------------------------------------------------------
	local renderer_mod = module.get("link.renderer")
	local code_bufs = find_buffers_by_paths(code_files)
	for bufnr, _ in pairs(code_bufs) do
		renderer_mod.render_code_status(bufnr)
	end
end

---------------------------------------------------------------------
-- ⭐ 统一事件入口（所有状态变化都应该调用这里）
---------------------------------------------------------------------

function M.on_state_changed(ev)
	-- ev = { source, file, bufnr, ids = {...} }

	table.insert(pending_events, ev)

	-- 重置 timer
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end

	timer = vim.loop.new_timer()
	timer:start(DEBOUNCE, 0, function()
		vim.schedule(function()
			local batch = pending_events
			pending_events = {}
			M.run_refresh_pipeline(batch)
		end)
	end)
end

return M
