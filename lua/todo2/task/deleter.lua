-- lua/todo2/task/deleter.lua
-- ⭐ 最终修复版：locator 行号兜底 + 立即 cleanup 删除 code link

local M = {}

local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local store_link = require("todo2.store.link")
local id_utils = require("todo2.utils.id")
local scheduler = require("todo2.render.scheduler")
local archive_link = require("todo2.store.link.archive")
local locator = require("todo2.store.locator")
local cleanup = require("todo2.store.cleanup")

---------------------------------------------------------------------
-- 工具：读取行
---------------------------------------------------------------------
local function read_line(filepath, lnum)
	local lines = scheduler.get_file_lines(filepath)
	return lines and lines[lnum] or nil
end

local function verify_line_contains_id(filepath, lnum, id)
	local text = read_line(filepath, lnum)
	return text and id_utils.extract_id(text) == id
end

local function resolve_current_line(link_obj)
	local located = locator.locate_task_sync(link_obj)
	return located and located.line or nil
end

---------------------------------------------------------------------
-- 删除行 + 自动保存
---------------------------------------------------------------------
function M.delete_lines(bufnr, lines)
	if not bufnr or not lines or #lines == 0 then
		return 0
	end

	table.sort(lines, function(a, b)
		return a > b
	end)

	for _, ln in ipairs(lines) do
		pcall(vim.api.nvim_buf_set_lines, bufnr, ln - 1, ln, false, {})
	end

	autosave.request_save(bufnr)
	return #lines
end

---------------------------------------------------------------------
-- 删除存储记录（TODO + CODE）
---------------------------------------------------------------------
function M.delete_store_records(ids)
	for _, id in ipairs(ids) do
		if archive_link.get_archive_snapshot(id) then
			archive_link.delete_archive_snapshot(id)
		end
		store_link.delete_todo(id)
		store_link.delete_code(id)
	end
end

---------------------------------------------------------------------
-- 获取选区
---------------------------------------------------------------------
function M._get_selection_range()
	local mode = vim.fn.mode()
	if mode == "v" or mode == "V" or mode == "" then
		local s = vim.fn.line("v")
		local e = vim.fn.line(".")
		if s > e then
			return e, s
		end
		return s, e
	end
	return vim.fn.line("."), vim.fn.line(".")
end

---------------------------------------------------------------------
-- 识别代码标记行
---------------------------------------------------------------------
function M._identify_marked_lines(bufnr, lines, start_lnum)
	local marked = {}
	for idx, line in ipairs(lines) do
		local actual_lnum = start_lnum + idx - 1
		local ids = {}

		if id_utils.contains_code_mark(line) then
			local id = id_utils.extract_id_from_code_mark(line)
			if id then
				table.insert(ids, id)
			end
		end

		if #ids > 0 then
			table.insert(marked, { lnum = actual_lnum, content = line, ids = ids })
		end
	end
	return marked
end

---------------------------------------------------------------------
-- ⭐ 删除 TODO 任务（locator 兜底 + 立即 cleanup）
---------------------------------------------------------------------
function M.delete_todo_task_line(id)
	local todo_link = store_link.get_todo(id)
	if not todo_link then
		return false
	end

	local todo_path = todo_link.path
	local todo_line = todo_link.line

	-- 行号过期 → locator 兜底
	if not verify_line_contains_id(todo_path, todo_line, id) then
		local resolved = resolve_current_line(todo_link)
		if not resolved or not verify_line_contains_id(todo_path, resolved, id) then
			return false
		end
		todo_line = resolved
	end

	-- 删除 TODO 行
	local bufnr = vim.fn.bufadd(todo_path)
	vim.fn.bufload(bufnr)
	M.delete_lines(bufnr, { todo_line })

	-- 删除 CODE 行
	local code_link = store_link.get_code(id)
	if code_link then
		local code_path = code_link.path
		local code_line = code_link.line

		if not verify_line_contains_id(code_path, code_line, id) then
			local resolved = resolve_current_line(code_link)
			if resolved and verify_line_contains_id(code_path, resolved, id) then
				code_line = resolved
			else
				code_line = nil
			end
		end

		if code_line then
			local bufnr2 = vim.fn.bufadd(code_path)
			vim.fn.bufload(bufnr2)
			M.delete_lines(bufnr2, { code_line })
		end
	end

	-- 删除存储记录
	M.delete_store_records({ id })

	-- ⭐ 立即 cleanup（确保 code link 不残留）
	cleanup.check_dangling_by_ids({ id }, { dry_run = false })

	return true
end

---------------------------------------------------------------------
-- ⭐ 删除 CODE 标记（locator 兜底 + 立即 cleanup）
---------------------------------------------------------------------
function M.delete_code_link()
	local bufnr = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(bufnr)

	local start_lnum, end_lnum = M._get_selection_range()
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)
	local marked_lines = M._identify_marked_lines(bufnr, lines, start_lnum)

	if #marked_lines == 0 then
		vim.notify("当前行/选区中没有找到任务标记", vim.log.levels.WARN)
		return
	end

	local delete_ids = {}
	local lines_to_delete = {}

	for _, mark in ipairs(marked_lines) do
		for _, id in ipairs(mark.ids) do
			if verify_line_contains_id(filepath, mark.lnum, id) then
				table.insert(delete_ids, id)
				table.insert(lines_to_delete, mark.lnum)
			else
				local code_link = store_link.get_code(id)
				if code_link then
					local resolved = resolve_current_line(code_link)
					if resolved and verify_line_contains_id(filepath, resolved, id) then
						table.insert(delete_ids, id)
						table.insert(lines_to_delete, resolved)
					end
				end
			end
		end
	end

	if #lines_to_delete > 0 then
		M.delete_lines(bufnr, lines_to_delete)
	end

	-- 删除 TODO 行
	local todo_by_file = {}

	for _, id in ipairs(delete_ids) do
		local todo_link = store_link.get_todo(id)
		if todo_link then
			local todo_path = todo_link.path
			local todo_line = todo_link.line

			if not verify_line_contains_id(todo_path, todo_line, id) then
				local resolved = resolve_current_line(todo_link)
				if resolved and verify_line_contains_id(todo_path, resolved, id) then
					todo_line = resolved
				else
					todo_line = nil
				end
			end

			if todo_line then
				todo_by_file[todo_path] = todo_by_file[todo_path] or {}
				table.insert(todo_by_file[todo_path], todo_line)
			end
		end
	end

	for file, lines in pairs(todo_by_file) do
		table.sort(lines, function(a, b)
			return a > b
		end)
		local bufnr2 = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr2)
		M.delete_lines(bufnr2, lines)
	end

	M.delete_store_records(delete_ids)

	-- ⭐ 立即 cleanup
	cleanup.check_dangling_by_ids(delete_ids, { dry_run = false })
end

---------------------------------------------------------------------
-- ⭐ 批量删除 TODO（locator 兜底 + 立即 cleanup）
---------------------------------------------------------------------
function M.batch_delete_todo_links(ids)
	if not ids or #ids == 0 then
		return false
	end

	local todo_by_file = {}
	local code_by_file = {}

	for _, id in ipairs(ids) do
		local todo_link = store_link.get_todo(id)
		if todo_link then
			local todo_path = todo_link.path
			local todo_line = todo_link.line

			if not verify_line_contains_id(todo_path, todo_line, id) then
				local resolved = resolve_current_line(todo_link)
				if resolved and verify_line_contains_id(todo_path, resolved, id) then
					todo_line = resolved
				else
					todo_line = nil
				end
			end

			if todo_line then
				todo_by_file[todo_path] = todo_by_file[todo_path] or {}
				table.insert(todo_by_file[todo_path], todo_line)
			end
		end

		local code_link = store_link.get_code(id)
		if code_link then
			local code_path = code_link.path
			local code_line = code_link.line

			if not verify_line_contains_id(code_path, code_line, id) then
				local resolved = resolve_current_line(code_link)
				if resolved and verify_line_contains_id(code_path, resolved, id) then
					code_line = resolved
				else
					code_line = nil
				end
			end

			if code_line then
				code_by_file[code_path] = code_by_file[code_path] or {}
				table.insert(code_by_file[code_path], code_line)
			end
		end
	end

	for file, lines in pairs(todo_by_file) do
		table.sort(lines, function(a, b)
			return a > b
		end)
		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)
		M.delete_lines(bufnr, lines)
	end

	for file, lines in pairs(code_by_file) do
		table.sort(lines, function(a, b)
			return a > b
		end)
		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)
		M.delete_lines(bufnr, lines)
	end

	M.delete_store_records(ids)

	-- ⭐ 立即 cleanup
	cleanup.check_dangling_by_ids(ids, { dry_run = false })

	return true
end

return M
