-- lua/todo2/task/deleter.lua
-- 无软删除版：所有删除行为均为彻底删除（TODO 行、CODE 行、链接对、快照）

local M = {}

---------------------------------------------------------------------
-- 依赖
---------------------------------------------------------------------
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local store_link = require("todo2.store.link")
local id_utils = require("todo2.utils.id")
local ui = require("todo2.ui")
local scheduler = require("todo2.render.scheduler")
local archive_link = require("todo2.store.link.archive")

---------------------------------------------------------------------
-- 批处理状态
---------------------------------------------------------------------
local batch_operations = {}
local batch_timer = nil
local BATCH_DELAY = 50

---------------------------------------------------------------------
-- 文件缓存（轻量）
---------------------------------------------------------------------
local file_cache = {}
local CACHE_TTL = 1000

local function clear_file_cache(filepath)
	for key, _ in pairs(file_cache) do
		if key:find(filepath, 1, true) then
			file_cache[key] = nil
		end
	end
end

---------------------------------------------------------------------
-- 验证代码标记是否存在
---------------------------------------------------------------------
local function verify_code_mark(filepath, line_num, expected_id)
	if not filepath or vim.fn.filereadable(filepath) ~= 1 then
		return false, "文件不存在"
	end

	local cache_key = filepath .. ":" .. line_num
	local cached = file_cache[cache_key]
	local line_content

	if cached and (vim.loop.now() - cached.time) < CACHE_TTL then
		line_content = cached.content
	else
		local lines = vim.fn.readfile(filepath)
		if line_num < 1 or line_num > #lines then
			return false, "行号超出范围"
		end
		line_content = lines[line_num]
		file_cache[cache_key] = { content = line_content, time = vim.loop.now() }
	end

	if not line_content then
		return false, "无法读取行内容"
	end

	local exists = line_content
		and id_utils.contains_code_mark(line_content)
		and id_utils.extract_id_from_code_mark(line_content) == expected_id

	return exists, exists and nil or "代码标记不存在"
end

---------------------------------------------------------------------
-- 删除行
---------------------------------------------------------------------
function M.delete_lines(bufnr, lines)
	if not bufnr or not lines or #lines == 0 then
		return 0
	end

	local unique = {}
	local seen = {}

	for _, ln in ipairs(lines) do
		if not seen[ln] then
			table.insert(unique, ln)
			seen[ln] = true
		end
	end

	table.sort(unique, function(a, b)
		return a > b
	end)

	for _, ln in ipairs(unique) do
		pcall(vim.api.nvim_buf_set_lines, bufnr, ln - 1, ln, false, {})
	end

	return #unique
end

---------------------------------------------------------------------
-- ⭐ 彻底删除存储记录（包括快照）
---------------------------------------------------------------------
function M.delete_store_records(ids)
	if not ids or #ids == 0 then
		return { deleted_todo = 0, deleted_code = 0 }
	end

	local result = { deleted_todo = 0, deleted_code = 0 }

	for _, id in ipairs(ids) do
		-- 删除快照
		local snapshot = archive_link.get_archive_snapshot(id)
		if snapshot then
			archive_link.delete_archive_snapshot(id)
		end

		-- 删除链接对
		if store_link.delete_todo(id) then
			result.deleted_todo = result.deleted_todo + 1
		end
		if store_link.delete_code(id) then
			result.deleted_code = result.deleted_code + 1
		end
	end

	return result
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
-- ⭐ 删除 TODO 任务行（彻底删除）
---------------------------------------------------------------------
function M.delete_todo_task_line(id)
	local todo_link = store_link.get_todo(id, { verify_line = true })
	if not todo_link then
		return false
	end

	local code_link = store_link.get_code(id, { verify_line = false })

	-- 删除 TODO 行
	local todo_bufnr = vim.fn.bufadd(todo_link.path)
	vim.fn.bufload(todo_bufnr)

	local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)
	if todo_link.line < 1 or todo_link.line > #lines then
		return false
	end

	M.delete_lines(todo_bufnr, { todo_link.line })

	-- 删除代码标记（如果存在）
	if code_link and code_link.path and code_link.line then
		local exists = verify_code_mark(code_link.path, code_link.line, id)
		if exists then
			local code_bufnr = vim.fn.bufadd(code_link.path)
			vim.fn.bufload(code_bufnr)
			M.delete_lines(code_bufnr, { code_link.line })
			autosave.request_save(code_bufnr)
		end
	end

	-- 删除快照 + 链接对
	M.delete_store_records({ id })

	autosave.request_save(todo_bufnr)
	return true
end

---------------------------------------------------------------------
-- ⭐ 删除代码标记（彻底删除）
---------------------------------------------------------------------
function M.delete_code_link(opts)
	opts = opts or {}
	local bufnr = vim.api.nvim_get_current_buf()

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
			local exists = verify_code_mark(vim.api.nvim_buf_get_name(bufnr), mark.lnum, id)
			if exists then
				table.insert(delete_ids, id)
				table.insert(lines_to_delete, mark.lnum)
			end
		end
	end

	-- 删除代码行
	if #lines_to_delete > 0 then
		M.delete_lines(bufnr, lines_to_delete)
		clear_file_cache(vim.api.nvim_buf_get_name(bufnr))
	end

	-- 删除 TODO 行 + 链接对 + 快照
	for _, id in ipairs(delete_ids) do
		local todo_link = store_link.get_todo(id, { verify_line = false })
		if todo_link then
			local todo_bufnr = vim.fn.bufadd(todo_link.path)
			vim.fn.bufload(todo_bufnr)
			M.delete_lines(todo_bufnr, { todo_link.line })
			autosave.request_save(todo_bufnr)
		end
	end

	M.delete_store_records(delete_ids)

	autosave.request_save(bufnr)
end

---------------------------------------------------------------------
-- ⭐ 批量删除 TODO 链接（彻底删除）
---------------------------------------------------------------------
function M.batch_delete_todo_links(ids, opts)
	opts = opts or {}
	if not ids or #ids == 0 then
		return false
	end

	local delete_ids = {}
	local by_file = {}

	for _, id in ipairs(ids) do
		local todo_link = store_link.get_todo(id, { verify_line = false })
		if todo_link then
			table.insert(delete_ids, id)

			local code_link = store_link.get_code(id, { verify_line = false })
			if code_link and code_link.path then
				if not by_file[code_link.path] then
					by_file[code_link.path] = { ids = {}, lines = {} }
				end
				table.insert(by_file[code_link.path].ids, id)
				if code_link.line then
					table.insert(by_file[code_link.path].lines, code_link.line)
				end
			end
		end
	end

	-- 删除代码行
	for file, data in pairs(by_file) do
		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)

		M.delete_lines(bufnr, data.lines)
		clear_file_cache(file)
		autosave.request_save(bufnr)
	end

	-- 删除 TODO 行
	for _, id in ipairs(delete_ids) do
		local todo_link = store_link.get_todo(id, { verify_line = false })
		if todo_link then
			local bufnr = vim.fn.bufadd(todo_link.path)
			vim.fn.bufload(bufnr)
			M.delete_lines(bufnr, { todo_link.line })
			autosave.request_save(bufnr)
		end
	end

	-- 删除链接对 + 快照
	M.delete_store_records(delete_ids)

	-- 事件
	if opts.todo_bufnr then
		events.on_state_changed({
			source = "batch_delete_todo_links",
			file = vim.api.nvim_buf_get_name(opts.todo_bufnr),
			bufnr = opts.todo_bufnr,
			ids = delete_ids,
		})
	end

	return true
end

---------------------------------------------------------------------
-- 清理
---------------------------------------------------------------------
function M.clear()
	batch_operations = {}
	if batch_timer then
		batch_timer:stop()
		batch_timer:close()
		batch_timer = nil
	end
	file_cache = {}
end

return M
