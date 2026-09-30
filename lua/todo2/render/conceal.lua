-- lua/todo2/render/conceal.lua
-- 精简版：仅处理 TODO 文件的 conceal 渲染

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local core = require("todo2.store.task.core")
local types = require("todo2.store.types")
local constants = require("todo2.constants")
local checkbox = require("todo2.render.checkbox")
local status_domain = require("todo2.core.status")

local NS_CONCEAL = constants.ns("conceal")
local NS_STRIKE = constants.ns("strike")

---------------------------------------------------------------------
-- 工具：行号有效性
---------------------------------------------------------------------
local function valid(buf, lnum)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	local total = vim.api.nvim_buf_line_count(buf)
	return lnum >= 1 and lnum <= total
end

---------------------------------------------------------------------
-- 删除线
---------------------------------------------------------------------
local function strike(buf, lnum, len)
	vim.api.nvim_buf_set_extmark(buf, NS_STRIKE, lnum - 1, 0, {
		end_col = len,
		hl_group = "TodoCompleted",
		hl_mode = "combine",
		priority = 5,
	})
end

---------------------------------------------------------------------
-- 清理
---------------------------------------------------------------------
function M.cleanup_buffer(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, NS_CONCEAL, 0, -1)
		vim.api.nvim_buf_clear_namespace(buf, NS_STRIKE, 0, -1)
	end
end

---------------------------------------------------------------------
-- 设置窗口 conceal 选项
---------------------------------------------------------------------
local function setup_window_conceal(buf)
	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		return
	end

	-- 仅设置窗口局部值（scope = "local"）。
	-- 直接使用 vim.wo[win].x = y 会像 :set 一样同时写入全局值，
	-- 导致 conceallevel=2 泄漏到后续新建的窗口（如 fff 的浮窗输入框），
	-- 使输入框内文字被 conceal、光标视觉上意外左移。
	pcall(function()
		vim.api.nvim_set_option_value("conceallevel", 2, { scope = "local", win = win })
		vim.api.nvim_set_option_value("concealcursor", "nvic", { scope = "local", win = win })
	end)
end

---------------------------------------------------------------------
-- 隐藏区间（统一入口）
---------------------------------------------------------------------
---@param buf number
---@param lnum number 1-based 行号
---@param start_col number 1-based 起始列
---@param end_col number 1-based 结束列（含）
---@param text string 替换文本（"" 表示完全隐藏）
---@param hl? string 替换文本的高亮组
local function conceal_range(buf, lnum, start_col, end_col, text, hl)
	vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, start_col - 1, {
		end_col = end_col,
		conceal = text,
		hl_group = hl,
	})
end

---------------------------------------------------------------------
-- 核心：单行渲染（仅 TODO 文件）
---------------------------------------------------------------------
function M.apply_line_conceal(buf, lnum)
	if not config.get("conceal_enable") then
		return false
	end
	if not valid(buf, lnum) then
		return false
	end

	setup_window_conceal(buf)

	-- 清理当前行的现有渲染
	vim.api.nvim_buf_clear_namespace(buf, NS_CONCEAL, lnum - 1, lnum)
	vim.api.nvim_buf_clear_namespace(buf, NS_STRIKE, lnum - 1, lnum)

	local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
	local len = #line

	-----------------------------------------------------------------
	-- 解析任务（仅 TODO 文件格式）
	-----------------------------------------------------------------
	local parsed = format.parse_task_line(line)
	if not parsed then
		return false
	end

	local id = parsed.id
	local task = id and core.get_task(id)

	-- 有效状态：优先 store，回退到文本 checkbox
	local status = task and task.core.status or status_domain.resolve_checkbox(parsed.checkbox)
	local is_completed = types.is_completed_status(status)
	local is_archived = status == types.STATUS.ARCHIVED

	-----------------------------------------------------------------
	-- checkbox 渲染（统一走共享 checkbox 模块）
	-----------------------------------------------------------------
	local cb_s, cb_e = format.get_checkbox_position(line)
	if cb_s and cb_e then
		local icon, icon_hl = checkbox.get(status)
		conceal_range(buf, lnum, cb_s, cb_e, icon, icon_hl)

		if is_completed or is_archived then
			strike(buf, lnum, len)
		end
	end

	-----------------------------------------------------------------
	-- 任务标记（<status>:<id>）隐去，编辑时只保留图标 + 内容
	-----------------------------------------------------------------
	local mk_s, mk_e = format.get_mark_position(line)
	if mk_s and mk_e then
		conceal_range(buf, lnum, mk_s, mk_e, "")
	end

	return true
end

---------------------------------------------------------------------
-- 范围渲染
---------------------------------------------------------------------
function M.apply_range_conceal(buf, s, e)
	local count = 0
	for l = s, e do
		local ok, r = pcall(M.apply_line_conceal, buf, l)
		if ok and r then
			count = count + 1
		end
	end
	return count
end

---------------------------------------------------------------------
-- 智能渲染（增量）
---------------------------------------------------------------------
function M.apply_smart_conceal(buf, changed)
	if not config.get("conceal_enable") then
		return 0
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return 0
	end

	setup_window_conceal(buf)

	local total = vim.api.nvim_buf_line_count(buf)

	if changed and #changed > 0 then
		local count = 0
		for _, l in ipairs(changed) do
			if type(l) == "number" and l >= 1 and l <= total then
				if M.apply_line_conceal(buf, l) then
					count = count + 1
				end
			end
		end
		return count
	end

	return M.apply_range_conceal(buf, 1, total)
end

---------------------------------------------------------------------
-- 全量渲染
---------------------------------------------------------------------
function M.apply_buffer_conceal(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return 0
	end

	setup_window_conceal(buf)
	M.cleanup_buffer(buf)

	local total = vim.api.nvim_buf_line_count(buf)
	return M.apply_range_conceal(buf, 1, total)
end

return M
