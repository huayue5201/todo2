-- lua/todo2/render/conceal.lua
-- 精简版：仅处理 TODO 文件的 conceal 渲染

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local id_utils = require("todo2.utils.id")
local core = require("todo2.store.link.core")
local types = require("todo2.store.types")
local constants = require("todo2.constants")

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

	pcall(function()
		vim.wo[win].conceallevel = 2
		vim.wo[win].concealcursor = "nv"
	end)
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
	local is_completed = task and types.is_completed_status(task.core.status)

	-----------------------------------------------------------------
	-- AI 图标渲染
	-----------------------------------------------------------------
	-- TODO: 删除AI相关代码
	local ai_executable = task and task.core.ai_executable or false
	if ai_executable then
		local indent = line:match("^(%s*)") or ""
		local indent_len = #indent

		vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, indent_len, {
			virt_text = { { "🤖 ", "Todo2AIIcon" } },
			virt_text_pos = "overlay",
			priority = 20,
		})
	end

	-----------------------------------------------------------------
	-- checkbox 渲染（优先按 store 状态，回退到文本）
	-----------------------------------------------------------------
	local checkbox = config.get("checkbox_icons", {
		todo = "◻",
		done = "✓",
		archived = "📦",
	})

	local cb_s, cb_e = format.get_checkbox_position(line)
	if cb_s and cb_e then
		local is_archived = task and task.core.status == types.STATUS.ARCHIVED
		local icon
		if is_archived then
			icon = checkbox.archived
		elseif is_completed then
			icon = checkbox.done
		elseif parsed.checkbox and parsed.checkbox:match("%[[xX]%]") then
			icon = checkbox.done
		elseif parsed.checkbox and parsed.checkbox:match("%[>%]") then
			icon = checkbox.archived
		else
			icon = checkbox.todo
		end

		vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, cb_s - 1, {
			end_col = cb_e,
			conceal = icon,
		})

		if is_completed or is_archived then
			strike(buf, lnum, len)
		end
	end

	-----------------------------------------------------------------
	-- ID 图标渲染（只隐藏 ID 部分，保留 tag）
	-----------------------------------------------------------------
	if parsed.id and parsed.tag then
		local tags_cfg = config.get("tags", {})
		local tag_cfg = tags_cfg[parsed.tag]
		local icon = tag_cfg and tag_cfg.id_icon
		if icon then
			-- 找到 ID 的位置（包括 :ref:）
			local id_pattern = id_utils.REF_SEPARATOR .. parsed.id
			local s, e = line:find(id_pattern, 1, true)
			if s then
				vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, s - 1, {
					end_col = e,
					conceal = icon,
				})
			end
		end
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
