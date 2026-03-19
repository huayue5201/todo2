-- lua/todo2/render/conceal.lua
-- 修复版：只隐藏 ID 部分，保留 tag

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local id_utils = require("todo2.utils.id")
local core = require("todo2.store.link.core")
local types = require("todo2.store.types")

local NS_CONCEAL = vim.api.nvim_create_namespace("todo2_conceal")
local NS_STRIKE = vim.api.nvim_create_namespace("todo2_strike")

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
-- 核心：单行渲染
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
	-- 解析 ID
	-----------------------------------------------------------------
	local parsed = format.parse_task_line(line)
	local todo_id = parsed and parsed.id or nil
	local code_id = id_utils.extract_id_from_code_mark(line)
	local id = todo_id or code_id

	-- 从存储获取任务状态
	local task = id and core.get_task(id)
	local is_completed = task and types.is_completed_status(task.core.status)

	-----------------------------------------------------------------
	-- AI 图标渲染
	-----------------------------------------------------------------
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
	-- checkbox 渲染
	-----------------------------------------------------------------
	local checkbox = config.get("checkbox_icons") or {
		todo = "◻",
		done = "✓",
		archived = "📦",
	}

	if line:find("%[%s%]") then
		local s, e = line:find("%[%s%]")
		vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, s - 1, {
			end_col = e,
			conceal = checkbox.todo,
		})
	elseif line:find("%[[xX]%]") then
		local s, e = line:find("%[[xX]%]")
		vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, s - 1, {
			end_col = e,
			conceal = checkbox.done,
		})
		if is_completed then
			strike(buf, lnum, len)
		end
	elseif line:find("%[>%]") then
		local s, e = line:find("%[>%]")
		vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, s - 1, {
			end_col = e,
			conceal = checkbox.archived,
		})
		strike(buf, lnum, len)
	end

	-----------------------------------------------------------------
	-- TODO 文件 ID 图标渲染（修复：只隐藏ID部分）
	-----------------------------------------------------------------
	if parsed and parsed.id and parsed.tag then
		local tags_cfg = config.get("tags") or {}
		local tag_cfg = tags_cfg[parsed.tag]
		local icon = tag_cfg and tag_cfg.id_icon
		if icon then
			-- 只找到ID的位置，不包括tag
			local id_pattern = id_utils.REF_SEPARATOR .. parsed.id
			local s, e = line:find(id_pattern, 1, true)
			if s then
				-- 从 ":" 开始隐藏（包括 :ref: 和 ID）
				vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, s - 1, {
					end_col = e,
					conceal = icon,
				})
			end
		end
		-- 注意：不返回 true，让代码继续执行可能的其他渲染
	end

	-----------------------------------------------------------------
	-- CODE 文件 ID 图标渲染（修复：只隐藏ID部分）
	-----------------------------------------------------------------
	if code_id then
		local tags_cfg = config.get("tags") or {}
		local tag = id_utils.extract_tag_from_code_mark(line)

		if tag then
			local tag_cfg = tags_cfg[tag]
			local icon = tag_cfg and tag_cfg.id_icon

			if icon then
				-- 找到ID的位置（不包括tag）
				local id_pattern = id_utils.REF_SEPARATOR .. code_id
				local s, e = line:find(id_pattern, 1, true)
				if s then
					vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, s - 1, {
						end_col = e,
						conceal = icon,
						priority = 10,
					})
				end
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
