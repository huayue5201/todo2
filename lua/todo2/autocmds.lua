-- lua/todo2/autocmds.lua
-- 极简事件层：不做同步，不做修复，只负责事件通知

local M = {}

local events = require("todo2.core.events")
local config = require("todo2.config")
local id_utils = require("todo2.utils.id")
local autosave = require("todo2.core.autosave")

local augroup = vim.api.nvim_create_augroup("Todo2", { clear = true })

local function is_valid(buf)
	return buf and vim.api.nvim_buf_is_valid(buf)
end

local function filepath(buf)
	return vim.api.nvim_buf_get_name(buf)
end

local function is_todo(path)
	return path:match("%.todo%.md$") or path:match("%.todo$")
end

---------------------------------------------------------------------
-- 初始渲染
---------------------------------------------------------------------
function M.setup_initial_render()
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		group = augroup,
		callback = function(args)
			local buf = args.buf
			if not is_valid(buf) then
				return
			end
			local path = filepath(buf)
			if path == "" then
				return
			end

			vim.defer_fn(function()
				if not is_valid(buf) then
					return
				end

				events.on_state_changed({
					source = "initial_render",
					file = path,
					bufnr = buf,
				})
			end, 30)
		end,
	})
end

---------------------------------------------------------------------
-- 文本变更（不做同步，只触发事件）
---------------------------------------------------------------------
function M.setup_text_change()
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		callback = function(args)
			local buf = args.buf
			if not is_valid(buf) then
				return
			end

			local path = filepath(buf)
			if path == "" then
				return
			end

			events.on_state_changed({
				source = "text_change",
				file = path,
				bufnr = buf,
			})
		end,
	})
end

---------------------------------------------------------------------
-- 保存事件（不做同步）
---------------------------------------------------------------------
function M.setup_write()
	-- TODO 文件自动保存（InsertLeave）
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		callback = function()
			local buf = vim.api.nvim_get_current_buf()
			if not is_valid(buf) then
				return
			end
			if not vim.api.nvim_get_option_value("modified", { buf = buf }) then
				return
			end

			local path = filepath(buf)
			if autosave.flush then
				autosave.flush(buf)
			end

			events.on_state_changed({
				source = "todo_autosave",
				file = path,
				bufnr = buf,
			})
		end,
	})

	-- 手动保存
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = "*",
		callback = function(args)
			local buf = args.buf
			if not is_valid(buf) then
				return
			end

			local path = filepath(buf)

			events.on_state_changed({
				source = "save",
				file = path,
				bufnr = buf,
			})
		end,
	})
end

---------------------------------------------------------------------
-- UI 渲染事件
---------------------------------------------------------------------
function M.setup_ui()
	vim.api.nvim_create_autocmd({ "BufWinEnter", "TextChanged", "BufWritePost" }, {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		callback = function(args)
			local buf = args.buf
			if not is_valid(buf) then
				return
			end

			local path = filepath(buf)
			if path == "" then
				return
			end

			events.on_state_changed({
				source = "todo_ui",
				file = path,
				bufnr = buf,
			})
		end,
	})
end

---------------------------------------------------------------------
-- 自动重定位（依赖 locator，不越界）
---------------------------------------------------------------------
function M.setup_autolocate()
	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		callback = function(args)
			if not config.get("auto_relocate") then
				return
			end

			local buf = args.buf
			if not is_valid(buf) then
				return
			end

			local path = filepath(buf)
			if path == "" then
				return
			end

			vim.schedule(function()
				local index = require("todo2.store.index")
				local todo_links = index.find_todo_links_by_file(path) or {}
				local code_links = index.find_code_links_by_file(path) or {}

				local ids = {}
				for _, l in ipairs(todo_links) do
					table.insert(ids, l.id)
				end
				for _, l in ipairs(code_links) do
					table.insert(ids, l.id)
				end

				if #ids > 0 then
					events.on_state_changed({
						source = "autolocate",
						file = path,
						bufnr = buf,
						changed_ids = ids,
					})
				end
			end)
		end,
	})
end

---------------------------------------------------------------------
-- 入口
---------------------------------------------------------------------
function M.setup()
	M.setup_initial_render()
	M.setup_text_change()
	M.setup_write()
	M.setup_ui()
	M.setup_autolocate()
end

return M
