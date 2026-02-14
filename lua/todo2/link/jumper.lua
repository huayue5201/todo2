-- lua/todo2/link/jumper.lua
--- @module todo2.link.jumper
--- @brief 负责代码 ↔ TODO 的跳转逻辑

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local store_types = require("todo2.store.types")
local link_mod = require("todo2.store.link")
local locator = require("todo2.store.locator")
local ui = require("todo2.ui")
local utils = require("todo2.link.utils")

---------------------------------------------------------------------
-- 硬编码配置
---------------------------------------------------------------------
local FIXED_CONFIG = {
	reuse_existing = true,
	keep_split = false,
}

---------------------------------------------------------------------
-- 工具函数：查找已存在的 TODO 窗口
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
-- 安全跳转工具函数
---------------------------------------------------------------------
local function safe_jump_to_line(win, line, col)
	col = col or 0

	if not vim.api.nvim_win_is_valid(win) then
		return false, "窗口无效"
	end

	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false, "缓冲区无效"
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	if line_count == 0 then
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
		return true
	end

	local target_line = math.max(1, math.min(line, line_count))

	local target_col = col
	local lines = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)
	if lines and #lines > 0 then
		target_col = math.min(target_col, #lines[1])
	else
		target_col = 0
	end

	local ok, err = pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })
	if not ok then
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
		return false, err
	end

	return true
end

---------------------------------------------------------------------
-- 检查链接是否已归档
---------------------------------------------------------------------
local function is_link_archived(link)
	if not link then
		return false
	end
	return link.status == store_types.STATUS.ARCHIVED or link.archived_at ~= nil
end

---------------------------------------------------------------------
-- ⭐ 修改：代码 → TODO（增强修复能力）
---------------------------------------------------------------------
function M.jump_to_todo()
	local line = vim.fn.getline(".")
	local tag, id = line:match("(%u+):ref:(%w+)")
	if not id then
		vim.notify("当前行没有链接标记", vim.log.levels.WARN)
		return
	end

	-- 使用 force_verify=true 强制验证和修复
	local link = link_mod.get_todo(id, { force_verify = true })
	if not link then
		-- 存储中找不到，尝试在全项目搜索
		vim.notify("存储中找不到链接，正在全项目搜索...", vim.log.levels.INFO)
		local found_path = locator.search_file_by_id(id)
		if found_path then
			local lines = vim.fn.readfile(found_path)
			for i, line_content in ipairs(lines) do
				if line_content:match("{#" .. id .. "}") then
					link_mod.add_todo(id, {
						path = found_path,
						line = i,
						content = line_content,
						status = "normal",
					})
					vim.notify("已重新建立链接", vim.log.levels.INFO)
					link = link_mod.get_todo(id, { force_verify = true })
					break
				end
			end
		end

		if not link then
			vim.notify("未找到 TODO 链接记录: " .. id, vim.log.levels.ERROR)
			return
		end
	end

	if is_link_archived(link) then
		vim.notify("链接 " .. id .. " 已归档", vim.log.levels.INFO)
	end

	local todo_path = vim.fn.fnamemodify(link.path, ":p")
	local todo_line = link.line or 1

	if vim.fn.filereadable(todo_path) == 0 then
		vim.notify("TODO文件不存在: " .. todo_path, vim.log.levels.ERROR)
		return
	end

	local bufnr = vim.fn.bufadd(todo_path)
	vim.fn.bufload(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	if todo_line < 1 or todo_line > line_count then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		for i, line_content in ipairs(lines) do
			if line_content:match("{#" .. id .. "}") then
				todo_line = i
				break
			end
		end

		if todo_line < 1 or todo_line > line_count then
			todo_line = 1
		end
	end

	local default_mode = config.get("link_default_window") or "float"
	local reuse_existing = FIXED_CONFIG.reuse_existing

	if reuse_existing then
		local win, win_bufnr = find_existing_todo_split_window(todo_path)
		if win then
			vim.api.nvim_set_current_win(win)
			safe_jump_to_line(win, todo_line, 0)
			return
		end
	end

	if ui and ui.open_todo_file then
		ui.open_todo_file(todo_path, default_mode, todo_line, {
			enter_insert = false,
		})
	end
end

---------------------------------------------------------------------
-- ⭐ 修改：TODO → 代码（增强修复能力）
---------------------------------------------------------------------
function M.jump_to_code()
	local line = vim.fn.getline(".")
	local id = line:match("{#(%w+)}")
	if not id then
		vim.notify("当前行没有代码链接", vim.log.levels.WARN)
		return
	end

	-- 使用 force_verify=true 强制验证和修复
	local link = link_mod.get_code(id, { force_verify = true })
	if not link then
		-- 存储中找不到，尝试在全项目搜索
		vim.notify("存储中找不到代码链接，正在全项目搜索...", vim.log.levels.INFO)
		local found_path = locator.search_file_by_id(id)
		if found_path then
			local lines = vim.fn.readfile(found_path)
			for i, line_content in ipairs(lines) do
				if line_content:match(":ref:" .. id) then
					link_mod.add_code(id, {
						path = found_path,
						line = i,
						content = line_content,
					})
					vim.notify("已重新建立代码链接", vim.log.levels.INFO)
					link = link_mod.get_code(id, { force_verify = true })
					break
				end
			end
		end

		if not link then
			vim.notify("未找到代码链接记录: " .. id, vim.log.levels.ERROR)
			return
		end
	end

	if is_link_archived(link) then
		vim.notify("链接 " .. id .. " 已归档", vim.log.levels.INFO)
	end

	local code_path = vim.fn.fnamemodify(link.path, ":p")
	local code_line = link.line or 1

	if vim.fn.filereadable(code_path) == 0 then
		vim.notify("代码文件不存在: " .. code_path, vim.log.levels.ERROR)
		return
	end

	local code_bufnr = vim.fn.bufadd(code_path)
	vim.fn.bufload(code_bufnr)
	local line_count = vim.api.nvim_buf_line_count(code_bufnr)

	if code_line < 1 or code_line > line_count then
		local lines = vim.api.nvim_buf_get_lines(code_bufnr, 0, -1, false)
		for i, line_content in ipairs(lines) do
			if line_content:match(":ref:" .. id) then
				code_line = i
				break
			end
		end

		if code_line < 1 or code_line > line_count then
			code_line = 1
		end
	end

	local current_win = vim.api.nvim_get_current_win()
	local is_float = false
	if utils and utils.is_todo_floating_window then
		is_float = utils.is_todo_floating_window(current_win)
	end

	local keep_split = FIXED_CONFIG.keep_split

	if is_float then
		vim.api.nvim_win_close(current_win, false)
		vim.schedule(function()
			vim.cmd("edit " .. vim.fn.fnameescape(code_path))
			local win = vim.api.nvim_get_current_win()
			safe_jump_to_line(win, code_line, 1)
		end)
		return
	end

	if keep_split then
		vim.cmd("vsplit")
		vim.cmd("edit " .. vim.fn.fnameescape(code_path))
		local win = vim.api.nvim_get_current_win()
		safe_jump_to_line(win, code_line, 1)
	else
		vim.cmd("edit " .. vim.fn.fnameescape(code_path))
		local win = vim.api.nvim_get_current_win()
		safe_jump_to_line(win, code_line, 1)
	end
end

---------------------------------------------------------------------
-- 动态跳转
---------------------------------------------------------------------
function M.jump_dynamic()
	local bufnr = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(bufnr)
	local ft = vim.api.nvim_buf_get_option(bufnr, "filetype")

	local is_todo = false
	if name ~= "" then
		is_todo = name:match("%.todo%.md$") ~= nil
	else
		is_todo = ft == "todo" or ft == "markdown"
	end

	if is_todo then
		M.jump_to_code()
	else
		M.jump_to_todo()
	end
end

return M
