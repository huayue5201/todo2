-- lua/todo2/link/jumper.lua
--- @module todo2.link.jumper
--- @brief 负责代码 ↔ TODO 的跳转逻辑（新 parser 架构）

local M = {}

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------

local store
local utils
local ui
local link_module
local syncer

local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

local function get_utils()
	if not utils then
		utils = require("todo2.link.utils")
	end
	return utils
end

local function get_ui()
	if not ui then
		ui = require("todo2.ui")
	end
	return ui
end

local function get_link_module()
	if not link_module then
		link_module = require("todo2.link")
	end
	return link_module
end

local function get_syncer()
	if not syncer then
		syncer = require("todo2.link.syncer")
	end
	return syncer
end

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------

local function get_config()
	return get_link_module().get_jump_config()
end

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
-- ⭐ 跳转：代码 → TODO
---------------------------------------------------------------------

function M.jump_to_todo()
	get_syncer().sync_code_links()

	local line = vim.fn.getline(".")
	local tag, id = line:match("(%u+):ref:(%w+)")
	if not id then
		vim.notify("当前行没有链接标记", vim.log.levels.WARN)
		return
	end

	local link = get_store().get_todo_link(id, { force_relocate = true })
	if not link then
		vim.notify("未找到 TODO 链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local todo_path = vim.fn.fnamemodify(link.path, ":p")
	local todo_line = link.line or 1

	local cfg = get_config()
	local default_mode = cfg.default_todo_window_mode or "float"
	local reuse_existing = cfg.reuse_existing_windows ~= false

	if reuse_existing then
		local win = find_existing_todo_split_window(todo_path)
		if win then
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(win, { todo_line, 0 })
			vim.cmd("normal! zz")
			return
		end
	end

	get_ui().open_todo_file(todo_path, default_mode, todo_line, {
		enter_insert = false,
	})
end

---------------------------------------------------------------------
-- ⭐ 跳转：TODO → 代码
---------------------------------------------------------------------

function M.jump_to_code()
	get_syncer().sync_todo_links()

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

	local current_win = vim.api.nvim_get_current_win()
	local is_float = get_utils().is_todo_floating_window(current_win)
	local cfg = get_config()
	local keep_split = cfg.keep_todo_split_when_jump or false

	if is_float then
		vim.api.nvim_win_close(current_win, false)
		vim.schedule(function()
			vim.cmd("edit " .. vim.fn.fnameescape(code_path))
			vim.fn.cursor(code_line, 1)
			vim.cmd("normal! zz")
		end)
		return
	end

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
