-- lua/todo2/link/jumper.lua
--- @module todo2.link.jumper
--- @brief 负责代码 ↔ TODO 的跳转逻辑（gj 的核心模块）
---
--- 设计目标：
--- 1. 跳转必须稳定、可恢复、可自动重新定位
--- 2. 与 store.lua 完全对齐（路径规范化、force_relocate）
--- 3. 支持浮窗、分屏、复用窗口等 UI 行为
--- 4. 所有函数带 LuaDoc 注释，便于未来维护

local M = {}

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------

local store
local utils
local ui
local link_module

--- 获取存储模块
local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

--- 获取工具模块
local function get_utils()
	if not utils then
		utils = require("todo2.link.utils")
	end
	return utils
end

--- 获取 UI 模块
local function get_ui()
	if not ui then
		ui = require("todo2.ui")
	end
	return ui
end

--- 获取 link 主模块（用于读取配置）
local function get_link_module()
	if not link_module then
		link_module = require("todo2.link")
	end
	return link_module
end

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------

--- 获取跳转配置
--- @return table
local function get_config()
	return get_link_module().get_jump_config()
end

---------------------------------------------------------------------
-- 工具函数：查找已打开的 TODO 分屏窗口
---------------------------------------------------------------------

--- 查找是否已有分屏窗口打开了指定 TODO 文件
--- @param todo_path string 绝对路径
--- @return integer|nil win_id, integer|nil bufnr
local function find_existing_todo_split_window(todo_path)
	local windows = vim.api.nvim_list_wins()

	for _, win in ipairs(windows) do
		if vim.api.nvim_win_is_valid(win) then
			local bufnr = vim.api.nvim_win_get_buf(win)
			local buf_path = vim.api.nvim_buf_get_name(bufnr)

			-- 路径必须规范化后比较
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
-- 跳转：代码 → TODO
---------------------------------------------------------------------

--- 从代码跳转到 TODO（gj 在代码文件中时调用）
--- @return nil
function M.jump_to_todo()
	local line = vim.fn.getline(".")
	local id = line:match("TODO:ref:(%w+)")

	if not id then
		vim.notify("当前行没有 TODO 链接", vim.log.levels.WARN)
		return
	end

	-- 使用 force_relocate，确保路径始终有效
	local link = get_store().get_todo_link(id, { force_relocate = true })

	if not link then
		vim.notify("未找到 TODO 链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local todo_path = vim.fn.fnamemodify(link.path, ":p")
	local todo_line = link.line or 1

	if vim.fn.filereadable(todo_path) == 0 then
		vim.notify("TODO 文件不存在: " .. todo_path, vim.log.levels.ERROR)
		return
	end

	local cfg = get_config()
	local default_mode = cfg.default_todo_window_mode or "float"
	local reuse_existing = cfg.reuse_existing_windows ~= false

	-- 复用已有分屏窗口
	if reuse_existing then
		local win, bufnr = find_existing_todo_split_window(todo_path)
		if win then
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(win, { todo_line, 0 })
			vim.cmd("normal! zz")
			return
		end
	end

	-- 打开 TODO 文件
	get_ui().open_todo_file(todo_path, default_mode, todo_line, {
		enter_insert = false,
	})
end

---------------------------------------------------------------------
-- 跳转：TODO → 代码
---------------------------------------------------------------------

--- 从 TODO 跳转到代码（gj 在 TODO 文件中时调用）
--- @return nil
function M.jump_to_code()
	local line = vim.fn.getline(".")
	local id = line:match("{#(%w+)}")

	if not id then
		vim.notify("当前行没有代码链接", vim.log.levels.WARN)
		return
	end

	local link = get_store().get_code_link(id, { force_relocate = true })

	if not link then
		vim.notify("未找到代码链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local code_path = vim.fn.fnamemodify(link.path, ":p")
	local code_line = link.line or 1

	if vim.fn.filereadable(code_path) == 0 then
		vim.notify("代码文件不存在: " .. code_path, vim.log.levels.ERROR)
		return
	end

	local current_win = vim.api.nvim_get_current_win()
	local is_float = get_utils().is_todo_floating_window(current_win)
	local cfg = get_config()
	local keep_split = cfg.keep_todo_split_when_jump or false

	if is_float then
		-- 关闭浮窗后跳转
		vim.api.nvim_win_close(current_win, false)
		vim.schedule(function()
			vim.cmd("edit " .. vim.fn.fnameescape(code_path))
			vim.fn.cursor(code_line, 1)
			vim.cmd("normal! zz")
		end)
		return
	end

	-- 分屏 TODO → 代码
	if keep_split then
		vim.cmd("vsplit")
		vim.cmd("edit " .. vim.fn.fnameescape(code_path))
		vim.fn.cursor(code_line, 1)
		vim.cmd("normal! zz")
	else
		vim.cmd("edit " .. vim.fn.fnameescape(code_path))
		vim.fn.cursor(code_line, 1)
		vim.cmd("normal! zz")
	end
end

---------------------------------------------------------------------
-- 动态跳转（gj）
---------------------------------------------------------------------

--- 动态跳转：自动判断当前 buffer 是代码还是 TODO
--- @return nil
function M.jump_dynamic()
	local bufnr = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("当前 buffer 无效", vim.log.levels.ERROR)
		return
	end

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
