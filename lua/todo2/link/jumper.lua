-- lua/todo2/link/jumper.lua
--- @module todo2.link.jumper
--- @brief 负责代码 ↔ TODO 的跳转逻辑

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local config = require("todo2.config")

---------------------------------------------------------------------
-- ⭐ 新增：导入存储类型常量
---------------------------------------------------------------------
local store_types = require("todo2.store.types")

---------------------------------------------------------------------
-- 硬编码配置（用户不需要调整）
---------------------------------------------------------------------
local FIXED_CONFIG = {
	reuse_existing = true, -- 总是重用窗口（减少窗口混乱）
	keep_split = false, -- 从TODO跳转时不保持分割（默认关闭浮动窗口）
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
-- ⭐ 安全跳转工具函数
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
		-- 空缓冲区，移动到第一行
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
		return true
	end

	-- 确保行号在有效范围内
	local target_line = math.max(1, math.min(line, line_count))

	-- 获取目标行的长度，确保列号有效
	local target_col = col
	local lines = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)
	if lines and #lines > 0 then
		target_col = math.min(target_col, #lines[1])
	else
		target_col = 0
	end

	-- 使用 pcall 安全地设置光标
	local ok, err = pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })
	if not ok then
		-- 如果失败，尝试使用第一行
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
		return false, err
	end

	return true
end

---------------------------------------------------------------------
-- ⭐ 修复：检查链接是否已归档
--- @param link table 链接对象
--- @return boolean 是否已归档
local function is_link_archived(link)
	if not link then
		return false
	end
	return link.status == store_types.STATUS.ARCHIVED or link.archived_at ~= nil
end

---------------------------------------------------------------------
-- ⭐ 跳转：代码 → TODO
---------------------------------------------------------------------
function M.jump_to_todo()
	local line = vim.fn.getline(".")
	local tag, id = line:match("(%u+):ref:(%w+)")
	if not id then
		vim.notify("当前行没有链接标记", vim.log.levels.WARN)
		return
	end

	-- ⭐ 修复：使用正确的模块路径
	local link_mod = module.get("store.link")
	if not link_mod then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

	local link = link_mod.get_todo(id, { verify_line = true })
	if not link then
		vim.notify("未找到 TODO 链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	-- ⭐ 新增：检查链接是否已归档
	if is_link_archived(link) then
		vim.notify("链接 " .. id .. " 已归档", vim.log.levels.INFO)
	end

	local todo_path = vim.fn.fnamemodify(link.path, ":p")

	-- ⭐ 关键修复：使用安全的任务查询
	local parser = module.get("core.parser")
	local task = nil
	if parser and parser.get_task_by_id then
		task = parser.get_task_by_id(todo_path, id)
	end

	if not task then
		-- ⭐ 修复：先检查链接是否已归档，已归档的任务不会出现在主任务树中
		if not is_link_archived(link) then
			-- 任务在解析树中不存在且未归档，需要清理
			vim.notify("任务 " .. id .. " 在文件中已不存在，清理存储记录", vim.log.levels.WARN)
			link_mod.delete_todo(id)
			link_mod.delete_code(id)
		end
		-- 即使已归档或不存在，仍然使用存储中的行号尝试跳转
		-- 归档的任务可能在归档区域
	end

	local todo_line = link.line or 1 -- 直接使用存储中的行号

	-- ⭐ 验证文件行数
	local bufnr = vim.fn.bufadd(todo_path)
	vim.fn.bufload(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	if todo_line < 1 or todo_line > line_count then
		-- 行号无效，尝试在文件中查找实际行号
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		for i, line_content in ipairs(lines) do
			if line_content:match("{#" .. id .. "}") then
				todo_line = i
				break
			end
		end

		-- 如果还是没找到，使用第一行
		if todo_line < 1 or todo_line > line_count then
			todo_line = 1
		end
	end

	-- 从配置获取窗口模式
	local default_mode = config.get("link_default_window") or "float"
	local reuse_existing = FIXED_CONFIG.reuse_existing

	if reuse_existing then
		local win, win_bufnr = find_existing_todo_split_window(todo_path)
		if win then
			vim.api.nvim_set_current_win(win)

			-- ⭐ 使用安全跳转
			safe_jump_to_line(win, todo_line, 0)

			-- 尝试滚动到中间
			pcall(vim.api.nvim_win_call, win, function() end)
			return
		end
	end

	local ui = module.get("ui")
	if ui and ui.open_todo_file then
		ui.open_todo_file(todo_path, default_mode, todo_line, {
			enter_insert = false,
		})
	end
end

---------------------------------------------------------------------
-- ⭐ 跳转：TODO → 代码
---------------------------------------------------------------------
-- FIX:ref:043b25
function M.jump_to_code()
	local line = vim.fn.getline(".")
	local id = line:match("{#(%w+)}")
	if not id then
		vim.notify("当前行没有代码链接", vim.log.levels.WARN)
		return
	end

	-- ⭐ 修复：使用正确的模块路径
	local link_mod = module.get("store.link")
	if not link_mod then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

	local link = link_mod.get_code(id, { verify_line = true })
	if not link then
		vim.notify("未找到代码链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	-- ⭐ 新增：检查链接是否已归档
	if is_link_archived(link) then
		vim.notify("链接 " .. id .. " 已归档", vim.log.levels.INFO)
	end

	local code_path = vim.fn.fnamemodify(link.path, ":p")
	local code_line = link.line or 1

	-- ⭐ 验证代码文件行数
	local code_bufnr = vim.fn.bufadd(code_path)
	vim.fn.bufload(code_bufnr)
	local line_count = vim.api.nvim_buf_line_count(code_bufnr)

	if code_line < 1 or code_line > line_count then
		-- 行号无效，尝试在文件中查找实际行号
		local lines = vim.api.nvim_buf_get_lines(code_bufnr, 0, -1, false)
		for i, line_content in ipairs(lines) do
			if line_content:match(":ref:" .. id) then
				code_line = i
				break
			end
		end

		-- 如果还是没找到，使用第一行
		if code_line < 1 or code_line > line_count then
			code_line = 1
		end
	end

	local current_win = vim.api.nvim_get_current_win()
	local utils = module.get("link.utils")
	local is_float = false
	if utils and utils.is_todo_floating_window then
		is_float = utils.is_todo_floating_window(current_win)
	end

	local keep_split = FIXED_CONFIG.keep_split

	if is_float then
		vim.api.nvim_win_close(current_win, false)
		vim.schedule(function()
			vim.cmd("edit " .. vim.fn.fnameescape(code_path))

			-- ⭐ 安全地设置光标
			local win = vim.api.nvim_get_current_win()
			safe_jump_to_line(win, code_line, 1)
		end)
		return
	end

	if keep_split then
		vim.cmd("vsplit")
		vim.cmd("edit " .. vim.fn.fnameescape(code_path))

		-- ⭐ 安全地设置光标
		local win = vim.api.nvim_get_current_win()
		safe_jump_to_line(win, code_line, 1)
	else
		vim.cmd("edit " .. vim.fn.fnameescape(code_path))

		-- ⭐ 安全地设置光标
		local win = vim.api.nvim_get_current_win()
		safe_jump_to_line(win, code_line, 1)
	end
end

---------------------------------------------------------------------
-- ⭐ 动态跳转
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
