-- lua/todo2/render/conceal.lua
-- 纯功能平移：使用新接口获取任务状态

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local id_utils = require("todo2.utils.id")
local core = require("todo2.store.link.core") -- 改为 core
local scheduler = require("todo2.render.scheduler")

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
-- 核心：单行渲染
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

	-----------------------------------------------------------------
	-- 0. AI 图标渲染（snapshot 优先）
	-----------------------------------------------------------------
	local path = vim.api.nvim_buf_get_name(buf)
	local _, _, id_to_task = scheduler.get_parse_tree(path, false)

	local id = id_utils.extract_id(line)
	local task = id and id_to_task and id_to_task[id] or nil

	-- snapshot 优先
	local ai_executable = false
	if task and task._store_ai_executable ~= nil then
		ai_executable = task._store_ai_executable
	elseif id then
		-- 从内部格式获取
		local t = core.get_task(id)
		ai_executable = t and t.core.ai_executable or false
	end

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
	-- 1. checkbox 渲染
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
	-- 2. TODO 文件 ID 图标渲染
	-----------------------------------------------------------------
	local parsed = format.parse_task_line(line)
	if parsed and parsed.id and parsed.tag then
		local tag_cfg = config.get("tags")[parsed.tag]
		local icon = tag_cfg and tag_cfg.id_icon
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
	-- 3. CODE 文件 ID 图标渲染
	-----------------------------------------------------------------
	if id then
		local tag = id_utils.extract_tag_from_code_mark(line) or "TODO"
		local tag_cfg = config.get("tags")[tag]
		local icon = tag_cfg and tag_cfg.id_icon
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
-- 全量渲染
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
