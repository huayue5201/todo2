local M = {}

local DEFAULT_DELAY = 200
local timers = {}
local pending = {}
local callbacks = {}
local global_callbacks = {}

local function safe_buf(bufnr)
	return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

local function do_save(bufnr)
	pending[bufnr] = true

	vim.schedule(function()
		local ok, err = pcall(vim.cmd, "silent! update")

		local result = {
			success = ok,
			bufnr = bufnr,
			filename = vim.api.nvim_buf_get_name(bufnr),
			error = ok and nil or err,
		}

		-- 执行 buffer 回调
		if callbacks[bufnr] then
			for _, cb in ipairs(callbacks[bufnr]) do
				pcall(cb, ok, err, result)
			end
		end

		-- 执行全局回调
		for _, cb in ipairs(global_callbacks) do
			pcall(cb, result)
		end

		pending[bufnr] = nil
		callbacks[bufnr] = nil
	end)
end

function M.request_save(bufnr, opts, cb)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	opts = opts or {}
	cb = cb or function() end

	if not safe_buf(bufnr) then
		cb(false, "invalid buffer")
		return
	end

	-- 清除旧 timer
	if timers[bufnr] then
		timers[bufnr]:stop()
		timers[bufnr]:close()
	end

	local timer = vim.uv.new_timer()
	timers[bufnr] = timer

	timer:start(opts.delay or DEFAULT_DELAY, 0, function()
		vim.schedule(function()
			timers[bufnr] = nil

			if not safe_buf(bufnr) then
				cb(false, "invalid buffer")
				return
			end

			if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
				cb(false, "not modified")
				return
			end

			M.flush(bufnr, cb)
		end)
	end)
end

function M.flush(bufnr, cb)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	cb = cb or function() end

	if not safe_buf(bufnr) then
		cb(false, "invalid buffer")
		return
	end

	if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
		cb(false, "not modified")
		return
	end

	-- 如果正在保存 → 合并
	if pending[bufnr] then
		callbacks[bufnr] = callbacks[bufnr] or {}
		table.insert(callbacks[bufnr], cb)
		return
	end

	callbacks[bufnr] = { cb }
	do_save(bufnr)
end

function M.flush_all()
	for bufnr, _ in pairs(timers) do
		M.flush(bufnr)
	end
end

function M.on_save_complete(cb)
	table.insert(global_callbacks, cb)
end

return M
