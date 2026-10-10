local M = {}

local async_util = require("todo2.utils.async")

local DEFAULT_DELAY = 200
local save_tasks = {}
local pending = {}
local callbacks = {}
local global_callbacks = {}

local function safe_buf(bufnr)
	return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

local function do_save(bufnr)
	pending[bufnr] = true

	async_util.defer(function()
		local ok, err = pcall(function()
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("silent! update")
			end)
		end)

		local filename = ""
		if safe_buf(bufnr) then
			filename = vim.api.nvim_buf_get_name(bufnr)
		end

		local result = {
			success = ok,
			bufnr = bufnr,
			filename = filename,
			error = ok and nil or err,
		}

		-- buffer 回调
		if callbacks[bufnr] then
			for _, cb in ipairs(callbacks[bufnr]) do
				pcall(cb, ok, err, result)
			end
		end

		-- 全局回调
		for _, cb in ipairs(global_callbacks) do
			pcall(cb, result)
		end

		pending[bufnr] = nil
		callbacks[bufnr] = nil
	end)
end

--- 取消某个 buffer 尚未执行的延迟保存。
---@param bufnr integer|nil
function M.cancel(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if save_tasks[bufnr] then
		async_util.cancel(save_tasks, bufnr)
	end
	pending[bufnr] = nil
	callbacks[bufnr] = nil
end

function M.request_save(bufnr, opts, cb)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	opts = opts or {}
	cb = cb or function() end

	if not safe_buf(bufnr) then
		cb(false, "invalid buffer")
		return
	end

	-- 防抖：取消同一 buffer 上一轮
	async_util.debounce(save_tasks, bufnr, opts.delay or DEFAULT_DELAY, function()
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

	-- 如果正在保存 → 合并回调
	if pending[bufnr] then
		callbacks[bufnr] = callbacks[bufnr] or {}
		table.insert(callbacks[bufnr], cb)
		return
	end

	callbacks[bufnr] = { cb }
	do_save(bufnr)
end

return M
