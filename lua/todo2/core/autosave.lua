-- lua/todo2/core/autosave.lua
--- @module todo2.core.autosave
--- @brief 自动保存模块（保持不变）

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

local function fire_refresh_event(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		return
	end

	local events_mod = module.get("core.events")
	local ids = {}

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for _, line in ipairs(lines) do
		local id = line:match("{#(%w+)}")
		if id then
			table.insert(ids, id)
		end

		local tag, tag_id = line:match("(%u+):ref:(%w+)")
		if tag_id then
			table.insert(ids, tag_id)
		end
	end

	if #ids == 0 then
		table.insert(ids, "autosave_" .. filepath:gsub("/", "_") .. "_" .. tostring(os.time()))
	end

	events_mod.on_state_changed({
		source = "autosave",
		file = filepath,
		bufnr = bufnr,
		ids = ids,
	})
end

---------------------------------------------------------------------
-- ⭐ 核心函数
---------------------------------------------------------------------
function M.request_save(bufnr, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	opts = opts or {}

	if not safe_buf(bufnr) then
		return
	end

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

			vim.api.nvim_buf_call(bufnr, function()
				local ok = pcall(vim.cmd, "silent write")
				if ok then
					fire_refresh_event(bufnr)
				end
			end)
		end)
	end)
end

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
-- 自动注册
---------------------------------------------------------------------
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		M.flush_all()
	end,
})

return M
