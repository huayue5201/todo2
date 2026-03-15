-- lua/todo2/core/autosave.lua
--- @module todo2.core.autosave
--- @brief 纯净的自动保存模块（只负责保存，不触发事件）

local M = {}

local DEFAULT_DELAY = 80
local timers = {}

local function safe_buf(bufnr)
	if type(bufnr) ~= "number" then
		return false
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return false
	end
	return true
end

-- ⭐ 使用 noautocmd write，避免触发 FileChangedShell
local function silent_write_noautocmd(bufnr)
	return pcall(vim.api.nvim_buf_call, bufnr, function()
		vim.cmd("silent noautocmd write")
	end)
end

function M.request_save(bufnr, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	opts = opts or {}

	if not safe_buf(bufnr) then
		return false, "buffer无效"
	end

	-- 合并重复写入
	if timers[bufnr] then
		timers[bufnr]:stop()
		timers[bufnr]:close()
		timers[bufnr] = nil
	end

	local timer = vim.loop.new_timer()
	timers[bufnr] = timer

	local delay = opts.delay or DEFAULT_DELAY

	timer:start(delay, 0, function()
		vim.schedule(function()
			if not safe_buf(bufnr) then
				return
			end

			if not vim.api.nvim_buf_get_option(bufnr, "modified") then
				return
			end

			local ok, err = silent_write_noautocmd(bufnr)
			if not ok then
				vim.notify("自动保存失败: " .. tostring(err), vim.log.levels.ERROR)
			end

			timers[bufnr] = nil
		end)
	end)

	return true
end

function M.flush(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if timers[bufnr] then
		timers[bufnr]:stop()
		timers[bufnr]:close()
		timers[bufnr] = nil
	end

	if safe_buf(bufnr) and vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
		local ok, err = silent_write_noautocmd(bufnr)
		if not ok then
			vim.notify("立即保存失败: " .. tostring(err), vim.log.levels.ERROR)
			return false
		end
		return true
	end

	return false
end

function M.flush_all()
	for bufnr, timer in pairs(timers) do
		timer:stop()
		timer:close()
		timers[bufnr] = nil

		if safe_buf(bufnr) and vim.api.nvim_buf_get_option(bufnr, "modified") then
			silent_write_noautocmd(bufnr)
		end
	end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		M.flush_all()
	end,
})

return M
