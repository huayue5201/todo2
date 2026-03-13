-- lua/todo2/link/jumper.lua
--- @module todo2.link.jumper
--- @brief 负责代码 ↔ TODO 的跳转逻辑（精简版：只负责跳转，不做修复/渲染/存储更新）

local M = {}

---------------------------------------------------------------------
-- 依赖（仅保留跳转所需）
---------------------------------------------------------------------
local link_mod = require("todo2.store.link")
local ui = require("todo2.ui")
local utils = require("todo2.task.utils")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 固定跳转配置（保留原版）
---------------------------------------------------------------------
local FIXED_CONFIG = {
	reuse_existing = true,
	jump_position = "auto",
}

---------------------------------------------------------------------
-- 查找已有 TODO split 窗口（保留原版）
---------------------------------------------------------------------
local function find_existing_todo_split_window(todo_path)
	local wins = vim.api.nvim_list_wins()
	for _, win in ipairs(wins) do
		if vim.api.nvim_win_is_valid(win) then
			local bufnr = vim.api.nvim_win_get_buf(win)
			local buf_path = vim.api.nvim_buf_get_name(bufnr)
			if vim.fn.fnamemodify(buf_path, ":p") == todo_path then
				local cfg = vim.api.nvim_win_get_config(win)
				if cfg.relative == "" then
					return win, bufnr
				end
			end
		end
	end
	return nil, nil
end

---------------------------------------------------------------------
-- 计算跳转列（保留原版）
---------------------------------------------------------------------
local function get_target_column(line_content, strategy)
	if strategy == "line_start" then
		return 0
	elseif strategy == "line_end" then
		return #line_content
	elseif strategy == "link_end" then
		if id_utils.contains_todo_anchor(line_content) then
			local id = id_utils.extract_id_from_todo_anchor(line_content)
			if id then
				local pattern = id_utils.format_todo_anchor(id)
				local _, e = line_content:find(pattern)
				if e then
					return e + 1
				end
			end
		end
		if id_utils.contains_code_mark(line_content) then
			local tag = id_utils.extract_tag_from_code_mark(line_content)
			local id = id_utils.extract_id_from_code_mark(line_content)
			if tag and id then
				local pattern = id_utils.format_code_mark(tag, id)
				local _, e = line_content:find(pattern)
				if e then
					return e + 1
				end
			end
		end
		return #line_content
	else
		if id_utils.contains_todo_anchor(line_content) or id_utils.contains_code_mark(line_content) then
			return get_target_column(line_content, "link_end")
		end
		return #line_content
	end
end

---------------------------------------------------------------------
-- 安全跳转（移除 highlight，不再触发跳动）
---------------------------------------------------------------------
local function safe_jump_to_line(win, line, col)
	col = col or -1
	local auto = col == -1

	if not vim.api.nvim_win_is_valid(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local target_line = math.max(1, math.min(line, line_count))
	local target_col = col

	local lines = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)
	if lines and #lines > 0 then
		local content = lines[1]
		if auto then
			target_col = get_target_column(content, FIXED_CONFIG.jump_position)
		else
			target_col = math.min(target_col, #content)
		end
	else
		target_col = 0
	end

	target_col = math.max(0, target_col)

	-- ⭐ 不再使用 highlight，不再使用 win_call，不再触发跳动
	pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })

	return true
end

---------------------------------------------------------------------
-- 代码 → TODO（精简版）
---------------------------------------------------------------------
function M.jump_to_todo()
	local line = vim.fn.getline(".")
	if not id_utils.contains_code_mark(line) then
		vim.notify("当前行没有链接标记", vim.log.levels.WARN)
		return
	end

	local id = id_utils.extract_id_from_code_mark(line)
	if not id then
		return
	end

	local link = link_mod.get_todo(id )
	if not link then
		vim.notify("未找到 TODO 链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local todo_path = vim.fn.fnamemodify(link.path, ":p")
	local todo_line = link.line or 1

	if FIXED_CONFIG.reuse_existing then
		local win = find_existing_todo_split_window(todo_path)
		if win then
			vim.api.nvim_set_current_win(win)
			safe_jump_to_line(win, todo_line, -1)
			return
		end
	end

	ui.open_todo_file(todo_path, "float", todo_line, { enter_insert = false })

	vim.schedule(function()
		local win = vim.api.nvim_get_current_win()
		safe_jump_to_line(win, todo_line, -1)
	end)
end

---------------------------------------------------------------------
-- TODO → 代码（精简版）
---------------------------------------------------------------------
function M.jump_to_code()
	local line = vim.fn.getline(".")
	if not id_utils.contains_todo_anchor(line) then
		vim.notify("当前行没有代码链接", vim.log.levels.WARN)
		return
	end

	local id = id_utils.extract_id_from_todo_anchor(line)
	if not id then
		return
	end

	local link = link_mod.get_code(id )
	if not link then
		vim.notify("未找到代码链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local code_path = vim.fn.fnamemodify(link.path, ":p")
	local code_line = link.line or 1

	local current_win = vim.api.nvim_get_current_win()
	local is_float = utils.is_todo_floating_window and utils.is_todo_floating_window(current_win)

	if is_float then
		vim.api.nvim_win_close(current_win, false)
		vim.schedule(function()
			vim.cmd("edit " .. vim.fn.fnameescape(code_path))
			safe_jump_to_line(vim.api.nvim_get_current_win(), code_line, -1)
		end)
		return
	end

	vim.cmd("edit " .. vim.fn.fnameescape(code_path))
	safe_jump_to_line(vim.api.nvim_get_current_win(), code_line, -1)
end

---------------------------------------------------------------------
-- 动态跳转（保留原版）
---------------------------------------------------------------------
function M.jump_dynamic()
	local name = vim.api.nvim_buf_get_name(0)
	local is_todo = name:match("%.todo%.md$") ~= nil
	if is_todo then
		M.jump_to_code()
	else
		M.jump_to_todo()
	end
end

return M
