-- lua/todo2/core/autosave.lua
--- @module todo2.core.autosave
--- @brief 纯保存模块（不触发事件）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local DEFAULT_DELAY = 80
local timers = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- ⭐ 核心函数：只保存，不触发事件
---------------------------------------------------------------------
function M.request_save(bufnr, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	opts = opts or {}

	if not safe_buf(bufnr) then
		return false, "buffer无效"
	end

	-- 检查是否已经在自动保存中
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

			-- 只有在buffer被修改时才保存
			if not vim.api.nvim_buf_get_option(bufnr, "modified") then
				return
			end

			-- ⭐ 直接保存，不触发事件
			local success, err = pcall(vim.api.nvim_buf_call, bufnr, function()
				vim.cmd("silent write")
			end)

			if not success then
				vim.notify("自动保存失败: " .. tostring(err), vim.log.levels.ERROR)
			end

			-- 清理定时器
			timers[bufnr] = nil
		end)
	end)

	return true
end

---------------------------------------------------------------------
-- ⭐ 立即保存函数
---------------------------------------------------------------------
function M.flush(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if timers[bufnr] then
		timers[bufnr]:stop()
		timers[bufnr]:close()
		timers[bufnr] = nil
	end

	if safe_buf(bufnr) and vim.api.nvim_buf_get_option(bufnr, "modified") then
		local success, err = pcall(vim.api.nvim_buf_call, bufnr, function()
			vim.cmd("silent write")
		end)

		if not success then
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
			pcall(vim.api.nvim_buf_call, bufnr, function()
				vim.cmd("silent write")
			end)
		end
	end
end

---------------------------------------------------------------------
-- 检查是否有等待的保存任务
---------------------------------------------------------------------
function M.has_pending_save(bufnr)
	if bufnr then
		return timers[bufnr] ~= nil
	else
		return next(timers) ~= nil
	end
end

---------------------------------------------------------------------
-- 自动注册
---------------------------------------------------------------------
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		M.flush_all()
	end,
})

return M
