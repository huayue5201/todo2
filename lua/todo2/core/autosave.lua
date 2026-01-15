-- lua/todo3/autosave.lua
-- 统一自动写盘调度器（防抖 + 合并 + 多 buffer 支持）
-- 设计目标：
-- 1. 所有操作都可以放心调用 request_save()
-- 2. 写盘自动合并，避免频繁 IO
-- 3. 写盘后自动触发 sync / render（依赖 BufWritePost）
-- 4. 写盘后自动刷新 UI（TODO buffer）与代码虚拟文本（code buffer）
-- 5. 可扩展（未来支持事务、批量 flush、延迟策略）

local M = {}

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local DEFAULT_DELAY = 200 -- 写盘防抖延迟（毫秒）

---------------------------------------------------------------------
-- 内部状态：每个 buffer 一个 timer
---------------------------------------------------------------------
local timers = {} -- [bufnr] = uv_timer

---------------------------------------------------------------------
-- 工具函数：安全检查 buffer
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
-- ⭐ buffer 类型判断（用于刷新 UI / 渲染）
---------------------------------------------------------------------
local function is_todo_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return false
	end
	return name:match("%.todo%.md$") ~= nil
end

local function is_code_buffer(bufnr)
	local ft = vim.api.nvim_buf_get_option(bufnr, "filetype")
	local code_fts = {
		lua = true,
		rust = true,
		go = true,
		python = true,
		javascript = true,
		typescript = true,
		c = true,
		cpp = true,
	}
	return code_fts[ft] == true
end

---------------------------------------------------------------------
-- ⭐ 写盘后刷新 UI / 渲染（核心增强）
---------------------------------------------------------------------
local function refresh_after_save(bufnr)
	-- TODO buffer → 刷新 todo UI
	if is_todo_buffer(bufnr) then
		pcall(function()
			local ui = require("todo2.ui")
			if ui and ui.refresh then
				ui.refresh(bufnr)
			end
		end)
	end

	-- 代码 buffer → 刷新代码侧虚拟文本
	if is_code_buffer(bufnr) then
		pcall(function()
			local renderer = require("todo2.link.renderer")
			if renderer and renderer.render_code_status then
				renderer.render_code_status(bufnr)
			end
		end)
	end
end

---------------------------------------------------------------------
-- ⭐ 核心函数：请求写盘（防抖 + 合并）
---------------------------------------------------------------------
function M.request_save(bufnr, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	opts = opts or {}

	if not safe_buf(bufnr) then
		return
	end

	-- 如果已有 timer，先停止
	if timers[bufnr] then
		timers[bufnr]:stop()
		timers[bufnr]:close()
		timers[bufnr] = nil
	end

	-- 创建新的 timer
	local timer = vim.loop.new_timer()
	timers[bufnr] = timer

	local delay = opts.delay or DEFAULT_DELAY

	timer:start(delay, 0, function()
		vim.schedule(function()
			-- 二次确认 buffer 是否仍然有效
			if not safe_buf(bufnr) then
				return
			end

			-- 如果 buffer 没有修改，不写盘
			if not vim.api.nvim_buf_get_option(bufnr, "modified") then
				return
			end

			-- ⭐ 在 buffer 上下文中执行写盘
			vim.api.nvim_buf_call(bufnr, function()
				local ok = pcall(vim.cmd, "silent write")
				if ok then
					-- ⭐ 写盘成功后刷新 UI / 渲染
					refresh_after_save(bufnr)
				end
			end)
		end)
	end)
end

---------------------------------------------------------------------
-- ⭐ 立即写盘（用于 VimLeavePre）
---------------------------------------------------------------------
function M.flush(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if timers[bufnr] then
		timers[bufnr]:stop()
		timers[bufnr]:close()
		timers[bufnr] = nil
	end

	if safe_buf(bufnr) and vim.api.nvim_buf_get_option(bufnr, "modified") then
		vim.api.nvim_buf_call(bufnr, function()
			local ok = pcall(vim.cmd, "silent write")
			if ok then
				refresh_after_save(bufnr)
			end
		end)
	end
end

---------------------------------------------------------------------
-- ⭐ flush 所有 buffer（退出 Neovim 时调用）
---------------------------------------------------------------------
function M.flush_all()
	for bufnr, timer in pairs(timers) do
		timer:stop()
		timer:close()
		timers[bufnr] = nil

		if safe_buf(bufnr) and vim.api.nvim_buf_get_option(bufnr, "modified") then
			vim.api.nvim_buf_call(bufnr, function()
				local ok = pcall(vim.cmd, "silent write")
				if ok then
					refresh_after_save(bufnr)
				end
			end)
		end
	end
end

---------------------------------------------------------------------
-- 自动注册：退出前 flush
---------------------------------------------------------------------
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		M.flush_all()
	end,
})

return M
