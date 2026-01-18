-- lua/todo2/core/autosave.lua
--- @module todo2.core.autosave
-- 专业版自动写盘调度器（防抖 + 合并 + 事件驱动刷新）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 懒加载依赖（使用模块管理器）
---------------------------------------------------------------------
local events
local function get_events()
	if not events then
		events = module.get("core.events")
	end
	return events
end

local store
local function get_store()
	if not store then
		store = module.get("store")
	end
	return store
end

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
-- ⭐ buffer 类型判断（用于事件系统）
---------------------------------------------------------------------
local function is_todo_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	return name ~= "" and name:match("%.todo%.md$")
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
-- ⭐ 写盘后触发事件（不直接刷新）
---------------------------------------------------------------------
local function fire_refresh_event(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		return
	end

	local store_mod = get_store()
	local events_mod = get_events()

	local ids = {}

	-- TODO 文件 → 找所有 {#id}
	if is_todo_buffer(bufnr) then
		local todo_links = store_mod.find_todo_links_by_file(filepath) or {}
		for _, link in ipairs(todo_links) do
			if link and link.id then
				table.insert(ids, link.id)
			end
		end
	end

	-- 代码文件 → 找所有 TAG:ref:id
	if is_code_buffer(bufnr) then
		local code_links = store_mod.find_code_links_by_file(filepath) or {}
		for _, link in ipairs(code_links) do
			if link and link.id then
				table.insert(ids, link.id)
			end
		end
	end

	if #ids == 0 then
		table.insert(ids, "autosave_" .. tostring(os.time()))
	end

	events_mod.on_state_changed({
		source = "autosave",
		file = filepath,
		bufnr = bufnr,
		ids = ids,
	})
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
					-- ⭐ 写盘成功后触发事件（不直接刷新）
					fire_refresh_event(bufnr)
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
				fire_refresh_event(bufnr)
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
					fire_refresh_event(bufnr)
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
