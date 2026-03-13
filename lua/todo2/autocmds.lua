-- lua/todo2/autocmds.lua
-- 完整整合版：TODO 权威 + snapshot 架构 + 自动 sync + 事件驱动

local M = {}

local events = require("todo2.core.events")
local config = require("todo2.config")
local id_utils = require("todo2.utils.id")
local autosave = require("todo2.core.autosave")
local index_mod = require("todo2.store.index")
local link_mod = require("todo2.store.link")
local hash = require("todo2.utils.hash")
local format = require("todo2.utils.format")

local augroup = vim.api.nvim_create_augroup("Todo2", { clear = true })

---------------------------------------------------------------------
-- 工具
---------------------------------------------------------------------
local function is_valid(buf)
	return buf and vim.api.nvim_buf_is_valid(buf)
end

local function filepath(buf)
	return vim.api.nvim_buf_get_name(buf)
end

local function is_todo(path)
	return path:match("%.todo%.md$") or path:match("%.todo$")
end

local function is_code(path)
	return path ~= "" and not is_todo(path)
end

---------------------------------------------------------------------
-- 扫描缓冲区所有 code 标记
---------------------------------------------------------------------
local function scan_all_ids(buf)
	local ids = {}
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for _, line in ipairs(lines) do
		if id_utils.contains_code_mark(line) then
			local id = id_utils.extract_id_from_code_mark(line)
			if id then
				ids[id] = true
			end
		end
	end
	local result = {}
	for id in pairs(ids) do
		table.insert(result, id)
	end
	return result
end

---------------------------------------------------------------------
-- 扫描受影响的行
---------------------------------------------------------------------
local function scan_changed_ids(buf, changed_lines)
	local ids = {}
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for _, l in ipairs(changed_lines) do
		local line = lines[l]
		if line and id_utils.contains_code_mark(line) then
			local id = id_utils.extract_id_from_code_mark(line)
			if id then
				ids[id] = true
			end
		end
	end
	local result = {}
	for id in pairs(ids) do
		table.insert(result, id)
	end
	return result
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

				if is_code(path) then
					local ids = scan_all_ids(buf)
					events.on_state_changed({
						source = "initial_render",
						file = path,
						bufnr = buf,
						changed_ids = ids,
					})
				elseif is_todo(path) then
					events.on_state_changed({
						source = "initial_render",
						file = path,
						bufnr = buf,
					})
				end
			end, 30)
		end,
	})
end

---------------------------------------------------------------------
-- 文本变更（增量）
-- TODO：只更新内容，不更新结构（结构由 sync_todo_links 负责）
-- CODE：扫描附近行的 ID
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

			-- 代码文件：扫描受影响的行
			if is_code(path) then
				local cursor = vim.api.nvim_win_get_cursor(0)
				local l = cursor and cursor[1] or 1
				local changed = { l - 2, l - 1, l, l + 1, l + 2 }

				local ids = scan_changed_ids(buf, changed)
				if #ids > 0 then
					events.on_state_changed({
						source = "code_edit",
						file = path,
						bufnr = buf,
						changed_ids = ids,
					})
				end
				return
			end

			-- TODO 文件：轻量内容更新（结构不在这里更新）
			if is_todo(path) then
				local cursor = vim.api.nvim_win_get_cursor(0)
				if not cursor then
					return
				end

				local line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1]
				if not line then
					return
				end

				local parsed = format.parse_task_line(line)
				if parsed and parsed.id then
					local todo = link_mod.get_todo(parsed.id)
					if todo and todo.content ~= parsed.content then
						local updated = vim.deepcopy(todo)
						updated.content = parsed.content
						updated.content_hash = hash.hash(parsed.content)
						updated.updated_at = os.time()
						link_mod.update_todo(parsed.id, updated)
					end
				end

				events.on_state_changed({
					source = "todo_edit",
					file = path,
					bufnr = buf,
				})
			end
		end,
	})
end

---------------------------------------------------------------------
-- 保存事件（TODO 权威模式）
-- TODO：autosave + 手动保存都 sync_todo_links
-- CODE：保存时 sync_code_links
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
			if autosave.flush and autosave.flush(buf) then
				local autofix = require("todo2.store.autofix")
				local report = autofix.sync_todo_links(path)
				local ids = report and report.ids or {}

				events.on_state_changed({
					source = "todo_autosave",
					file = path,
					bufnr = buf,
					changed_ids = ids,
				})
			end
		end,
	})

	-- TODO 文件手动保存（BufWritePost）
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		callback = function(args)
			local buf = args.buf
			if not is_valid(buf) then
				return
			end

			local path = filepath(buf)
			local autofix = require("todo2.store.autofix")
			local report = autofix.sync_todo_links(path)
			local ids = report and report.ids or {}

			events.on_state_changed({
				source = "todo_save",
				file = path,
				bufnr = buf,
				changed_ids = ids,
			})
		end,
	})

	-- 代码文件保存 → 同步链接
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = "*",
		callback = function(args)
			local buf = args.buf
			if not is_valid(buf) then
				return
			end
			local path = filepath(buf)
			if not is_code(path) then
				return
			end

			local autofix = require("todo2.store.autofix")
			if not autofix.should_process_file(path) then
				return
			end

			local report = autofix.sync_code_links(path)
			local ids = report and report.ids or {}

			events.on_state_changed({
				source = "code_save",
				file = path,
				bufnr = buf,
				changed_ids = ids,
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
-- 自动重定位（事件驱动）
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
