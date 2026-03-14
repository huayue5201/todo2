-- lua/todo2/core/events.lua
-- 极简事件系统：TODO + CODE 都刷新，但不扫描、不同步、不越界

local M = {}

local scheduler = require("todo2.render.scheduler")

---------------------------------------------------------------------
-- 事件队列（防抖）
---------------------------------------------------------------------
local pending = {}
local timer = nil
local DEBOUNCE = 30

---------------------------------------------------------------------
-- 事件入口
---------------------------------------------------------------------
function M.on_state_changed(ev)
	ev = ev or {}
	ev.timestamp = os.time() * 1000

	table.insert(pending, ev)

	if timer then
		timer:stop()
		timer:close()
	end

	timer = vim.loop.new_timer()
	timer:start(DEBOUNCE, 0, function()
		vim.schedule(function()
			local batch = pending
			pending = {}
			M._process(batch)
		end)
	end)
end

---------------------------------------------------------------------
-- 事件处理：TODO + CODE 都刷新（snapshot-first）
---------------------------------------------------------------------
function M._process(events)
	if #events == 0 then
		return
	end

	-- 收集受影响的文件
	local files = {}
	for _, ev in ipairs(events) do
		if ev.file then
			files[ev.file] = true
		end
		if ev.files then
			for _, f in ipairs(ev.files) do
				files[f] = true
			end
		end
	end

	for path, _ in pairs(files) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			-- ⭐ TODO + CODE 都刷新，但不扫描 CODE 文件
			scheduler.invalidate_cache(path)
			scheduler.refresh(bufnr, {
				from_event = true,
				force_refresh = false,
			})
		end
	end
end

return M
