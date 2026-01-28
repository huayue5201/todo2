-- lua/todo2/core/events.lua
--- @module todo2.core.events
--- @brief 精简版事件系统

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local pending_events = {}
local timer = nil
local DEBOUNCE = 50

---------------------------------------------------------------------
-- 合并事件并触发刷新
---------------------------------------------------------------------
local function process_events(events)
	if #events == 0 then
		return
	end

	local affected_files = {}
	local store_mod = module.get("store")

	for _, ev in ipairs(events) do
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

	-- 清理解析器缓存
	local parser_mod = module.get("core.parser")
	for path, _ in pairs(affected_files) do
		parser_mod.clear_cache(path)
	end

	-- 刷新相关buffer
	local ui_mod = module.get("ui")
	local renderer_mod = module.get("link.renderer")

	for path, _ in pairs(affected_files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			if path:match("%.todo%.md$") and ui_mod and ui_mod.refresh then
				ui_mod.refresh(bufnr)
			elseif renderer_mod and renderer_mod.render_code_status then
				renderer_mod.render_code_status(bufnr)
			end
		end
	end
end

---------------------------------------------------------------------
-- ⭐ 统一事件入口
---------------------------------------------------------------------
function M.on_state_changed(ev)
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

return M
