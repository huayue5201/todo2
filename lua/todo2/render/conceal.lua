-- lua/todo2/render/conceal.lua
-- 最终版：写入即真相，不做动态匹配，不做正则推断

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local id_utils = require("todo2.utils.id")

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
-- 工具：获取 id_icon（唯一真相源）
---------------------------------------------------------------------
local function get_id_icon(tag)
	local tags = config.get("tags") or {}
	local cfg = tags[tag]
	return cfg and cfg.id_icon or nil
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
-- 核心：单行 conceal（完全结构化）
---------------------------------------------------------------------
function M.apply_line_conceal(buf, lnum)
	if not config.get("conceal_enable") then
		return false
	end
	if not valid(buf, lnum) then
		return false
	end

	vim.api.nvim_buf_clear_namespace(buf, NS_CONCEAL, lnum - 1, lnum)
	vim.api.nvim_buf_clear_namespace(buf, NS_STRIKE, lnum - 1, lnum)

	local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
	local len = #line

	local checkbox = config.get("checkbox_icons") or {
		todo = "◻",
		done = "✓",
		archived = "📦",
	}

	-----------------------------------------------------------------
	-- 1. checkbox（写入即真相）
	-----------------------------------------------------------------
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
		strike(buf, lnum, len)
	elseif line:find("%[>%]") then
		local s, e = line:find("%[>%]")
		vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, s - 1, {
			end_col = e,
			conceal = checkbox.archived,
		})
		strike(buf, lnum, len)
	end

	-----------------------------------------------------------------
	-- 2. TODO 文件（结构化解析）
	-----------------------------------------------------------------
	local parsed = format.parse_task_line(line)
	if parsed and parsed.id and parsed.tag then
		local icon = get_id_icon(parsed.tag)
		if icon then
			local s, e = line:find("{#" .. parsed.id .. "}")
			if s then
				vim.api.nvim_buf_set_extmark(buf, NS_CONCEAL, lnum - 1, s - 1, {
					end_col = e,
					conceal = icon,
				})
			end
		end
		return true
	end

	-----------------------------------------------------------------
	-- 3. CODE 文件（结构化格式 TAG:ref:ID）
	-----------------------------------------------------------------
	local id = id_utils.extract_id(line)
	if id then
		local tag = id_utils.extract_tag_from_code_mark(line) or "TODO"
		local icon = get_id_icon(tag)
		if icon then
			local s, e = line:find(id_utils.REF_SEPARATOR .. id, 1, true)
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
-- 范围 conceal
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
-- 智能 conceal（增量）
---------------------------------------------------------------------
function M.apply_smart_conceal(buf, changed)
	if not config.get("conceal_enable") then
		return 0
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return 0
	end

	M.setup_window_conceal(buf)

	local total = vim.api.nvim_buf_line_count(buf)

	if changed and #changed > 0 then
		local count = 0
		for _, l in ipairs(changed) do
			if l >= 1 and l <= total then
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
-- 全量 conceal
---------------------------------------------------------------------
function M.apply_buffer_conceal(buf)
	M.cleanup_buffer(buf)
	local total = vim.api.nvim_buf_line_count(buf)
	return M.apply_range_conceal(buf, 1, total)
end

---------------------------------------------------------------------
-- 窗口设置
---------------------------------------------------------------------
function M.setup_window_conceal(buf)
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		vim.api.nvim_set_option_value("conceallevel", 2, { win = win })
		vim.api.nvim_set_option_value("concealcursor", "nv", { win = win })
	end
end

return M
