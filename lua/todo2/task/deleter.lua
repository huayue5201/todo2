-- lua/todo2/task/deleter.lua
-- 删除无用函数后的精简版本

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local store_link = require("todo2.store.link")
local renderer = require("todo2.render.code_render")
local ui = require("todo2.ui")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 类型定义
---------------------------------------------------------------------
--- @class BatchOperationData
--- @field ids table<string, boolean>
--- @field archived_ids? table<string, boolean>
--- @field lines_to_delete? number[]

--- @class DeleteResult
--- @field deleted_todo number
--- @field deleted_code number

--- @class MarkedLine
--- @field lnum number
--- @field content string
--- @field ids string[]

--- @class FileGroupData
--- @field ids string[]
--- @field lines number[]

---------------------------------------------------------------------
-- 批量操作状态
---------------------------------------------------------------------
--- @type table<number, BatchOperationData>
local batch_operations = {}

--- @type uv_timer_t?
local batch_timer = nil
local BATCH_DELAY = 50

---------------------------------------------------------------------
-- 辅助函数（内部使用）
---------------------------------------------------------------------
--- @param source string
--- @param bufnr number
--- @param ids string[]
--- @param files? string[] 可选的文件列表
local function trigger_state_change(source, bufnr, ids, files)
	if #ids == 0 then
		return
	end

	local event_data = {
		source = source,
		file = vim.api.nvim_buf_get_name(bufnr),
		bufnr = bufnr,
		ids = ids,
	}

	-- ⭐ 修复：如果有额外的文件列表，添加到事件中
	if files and #files > 0 then
		event_data.files = files
	end

	if not events.is_event_processing(event_data) then
		events.on_state_changed(event_data)
	end
end

--- @param bufnr number
--- @param source string?
--- @param ids string[]?
--- @param files string[]?
local function save_and_trigger(bufnr, source, ids, files)
	if not bufnr then
		return
	end

	if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
		autosave.flush(bufnr)
	end

	local save_event = {
		source = "deleter_save",
		file = vim.api.nvim_buf_get_name(bufnr),
		bufnr = bufnr,
	}

	if events and not events.is_event_processing(save_event) then
		events.on_state_changed(save_event)
	end

	if source and ids and #ids > 0 then
		-- ⭐ 修复：传递文件列表
		trigger_state_change(source, bufnr, ids, files)
	end
end

---------------------------------------------------------------------
-- 新增：执行批量删除（内部函数）
---------------------------------------------------------------------
--- @param bufnr number
--- @param active_ids string[]
--- @param archived_ids string[]
--- @param lines_to_delete number[]?
--- @param todo_files? string[] 关联的TODO文件列表
local function execute_batch_delete(bufnr, active_ids, archived_ids, lines_to_delete, todo_files)
	-- 1. 批量删除文件行
	if lines_to_delete and #lines_to_delete > 0 then
		M.delete_lines(bufnr, lines_to_delete)
	end

	-- 2. 处理非归档任务
	if #active_ids > 0 then
		-- 批量标记上下文为已删除
		local code_links = {}
		for _, id in ipairs(active_ids) do
			code_links[id] = store_link.get_code(id, { verify_line = false })
		end

		for id, code_link in pairs(code_links) do
			if code_link and code_link.context then
				code_link.context_valid = false
				code_link.context_deleted_at = os.time()
				store_link.update_code(id, code_link)
			end
		end

		-- 批量删除存储记录
		M.delete_store_records(active_ids)

		-- ⭐ 修复：批量触发事件，传递所有受影响的文件
		local all_files = { vim.api.nvim_buf_get_name(bufnr) }
		if todo_files then
			for _, file in ipairs(todo_files) do
				if not vim.tbl_contains(all_files, file) then
					table.insert(all_files, file)
				end
			end
		end

		save_and_trigger(bufnr, "batch_delete", active_ids, all_files)
	end

	-- 3. 归档任务只提示
	if #archived_ids > 0 then
		vim.notify(
			string.format("📦 跳过了 %d 个归档任务的存储删除", #archived_ids),
			vim.log.levels.DEBUG
		)
	end
end

---------------------------------------------------------------------
-- 修改：处理批量删除操作
---------------------------------------------------------------------
local function process_batch_operations()
	if vim.tbl_isempty(batch_operations) then
		return
	end

	local operations_to_process = vim.deepcopy(batch_operations)
	batch_operations = {}

	for bufnr, data in pairs(operations_to_process) do
		local active_ids = {}
		for id, _ in pairs(data.ids or {}) do
			table.insert(active_ids, id)
		end

		local archived_ids = {}
		for id, _ in pairs(data.archived_ids or {}) do
			table.insert(archived_ids, id)
		end

		if #active_ids > 0 or #archived_ids > 0 then
			-- ⭐ 修复：收集受影响的TODO文件
			local todo_files = {}
			for _, id in ipairs(active_ids) do
				local todo_link = store_link.get_todo(id, { verify_line = false })
				if todo_link and todo_link.path then
					if not vim.tbl_contains(todo_files, todo_link.path) then
						table.insert(todo_files, todo_link.path)
					end
				end
			end

			-- 执行批量删除，传递TODO文件列表
			execute_batch_delete(bufnr, active_ids, archived_ids, data.lines_to_delete, todo_files)
		end
	end

	if batch_timer then
		batch_timer:stop()
		batch_timer:close()
		batch_timer = nil
	end
end

---------------------------------------------------------------------
-- 修改：批量添加到批处理队列
---------------------------------------------------------------------
--- @param bufnr number
--- @param ids string[]
--- @param operation_type string?
local function add_to_batch(bufnr, ids, operation_type)
	if not ids or #ids == 0 then
		return
	end

	if not batch_operations[bufnr] then
		batch_operations[bufnr] = {
			ids = {},
			archived_ids = {},
			lines_to_delete = {},
		}
	end

	for _, id in ipairs(ids) do
		batch_operations[bufnr].ids[id] = true
	end

	if operation_type == "archived" then
		if not batch_operations[bufnr].archived_ids then
			batch_operations[bufnr].archived_ids = {}
		end
		for _, id in ipairs(ids) do
			batch_operations[bufnr].archived_ids[id] = true
		end
	end

	process_batch_operations()
end

---------------------------------------------------------------------
-- 核心函数 1：物理删除文件中的行
---------------------------------------------------------------------
--- @param bufnr number
--- @param lines number[]
--- @return number
function M.delete_lines(bufnr, lines)
	if not bufnr or not lines or #lines == 0 then
		return 0
	end

	local unique_lines = {}
	local seen = {}

	for _, ln in ipairs(lines) do
		if not seen[ln] then
			table.insert(unique_lines, ln)
			seen[ln] = true
		end
	end

	table.sort(unique_lines, function(a, b)
		return a > b
	end)

	for _, ln in ipairs(unique_lines) do
		local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, ln - 1, ln, false, {})
		if not ok then
			vim.notify("删除行失败: " .. tostring(err), vim.log.levels.ERROR)
		end
	end

	return #unique_lines
end

---------------------------------------------------------------------
-- 核心函数 2：从存储中删除链接记录
---------------------------------------------------------------------
--- @param ids string[]
--- @return DeleteResult
function M.delete_store_records(ids)
	if not ids or #ids == 0 then
		return { deleted_todo = 0, deleted_code = 0 }
	end

	local result = { deleted_todo = 0, deleted_code = 0 }

	for _, id in ipairs(ids) do
		local snapshot = store_link.get_archive_snapshot(id)
		if snapshot then
			vim.notify(
				string.format("⚠️ 删除有快照的链接 %s，快照将保留", id:sub(1, 6)),
				vim.log.levels.WARN
			)
		end

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
-- 辅助函数：获取选择范围
---------------------------------------------------------------------
--- @return number, number
function M._get_selection_range()
	local mode = vim.fn.mode()
	if mode == "v" or mode == "V" or mode == "" then
		local start = vim.fn.line("v")
		local end_ = vim.fn.line(".")
		if start > end_ then
			return end_, start
		end
		return start, end_
	end
	return vim.fn.line("."), vim.fn.line(".")
end

---------------------------------------------------------------------
-- 修改：识别包含标记的行（使用id_utils）
---------------------------------------------------------------------
--- @param bufnr number
--- @param lines string[]
--- @param start_lnum number
--- @return MarkedLine[]
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
			table.insert(marked, {
				lnum = actual_lnum,
				content = line,
				ids = ids,
			})
		end
	end

	return marked
end

---------------------------------------------------------------------
-- 修改：删除TODO任务行（使用id_utils验证）
---------------------------------------------------------------------
--- @param id string
--- @return boolean
function M.delete_todo_task_line(id)
	local todo_link = store_link.get_todo(id, { verify_line = true })
	if not todo_link then
		return false
	end

	local code_link = store_link.get_code(id, { verify_line = false })

	local todo_bufnr = vim.fn.bufadd(todo_link.path)
	vim.fn.bufload(todo_bufnr)

	local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)
	if todo_link.line < 1 or todo_link.line > #lines then
		return false
	end

	local line_content = lines[todo_link.line]
	if
		not line_content
		or not id_utils.contains_todo_anchor(line_content)
		or not id_utils.extract_id_from_todo_anchor(line_content) == id
	then
		return false
	end

	M.delete_lines(todo_bufnr, { todo_link.line })

	if todo_link.status == "archived" then
		if code_link and code_link.path and code_link.line then
			local code_bufnr = vim.fn.bufadd(code_link.path)
			vim.fn.bufload(code_bufnr)

			local code_lines = vim.api.nvim_buf_get_lines(code_bufnr, 0, -1, false)
			if code_link.line >= 1 and code_link.line <= #code_lines then
				local code_line = code_lines[code_link.line]
				if
					code_line
					and id_utils.contains_code_mark(code_line)
					and id_utils.extract_id_from_code_mark(code_line) == id
				then
					M.delete_lines(code_bufnr, { code_link.line })
					autosave.request_save(code_bufnr)
				end
			end
		end

		local status_mod = require("todo2.store.link.status")
		status_mod.mark_deleted(id, "archived_task_cleanup")

		autosave.request_save(todo_bufnr)
		return true
	end

	add_to_batch(todo_bufnr, { id })
	return true
end

---------------------------------------------------------------------
-- 修改：delete_code_link（修复事件触发）
---------------------------------------------------------------------
--- @param opts table?
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

	local all_ids = {}
	local archived_ids = {}
	local lines_to_delete = {}

	local todo_by_file = {}

	for _, mark in ipairs(marked_lines) do
		for _, id in ipairs(mark.ids) do
			local todo_link = store_link.get_todo(id, { verify_line = false })
			if todo_link and todo_link.path and todo_link.line then
				if todo_link.status == "archived" then
					table.insert(archived_ids, id)
				else
					table.insert(all_ids, id)

					if not todo_by_file[todo_link.path] then
						todo_by_file[todo_link.path] = { ids = {}, todo_lines = {} }
					end
					table.insert(todo_by_file[todo_link.path].ids, id)
					todo_by_file[todo_link.path].todo_lines[todo_link.line] = true
				end
			end
		end
		table.insert(lines_to_delete, mark.lnum)
	end

	if #lines_to_delete > 0 then
		M.delete_lines(bufnr, lines_to_delete)
	end

	for filepath, data in pairs(todo_by_file) do
		local todo_bufnr = vim.fn.bufadd(filepath)
		vim.fn.bufload(todo_bufnr)

		local todo_lines = {}
		for line, _ in pairs(data.todo_lines) do
			table.insert(todo_lines, line)
		end
		table.sort(todo_lines, function(a, b)
			return a > b
		end)

		M.delete_lines(todo_bufnr, todo_lines)

		local parser = require("todo2.core.parser")
		parser.invalidate_cache(filepath)

		autosave.request_save(todo_bufnr)
	end

	if #all_ids > 0 then
		M.delete_store_records(all_ids)
	end

	if #archived_ids > 0 then
		for _, id in ipairs(archived_ids) do
			local code_link = store_link.get_code(id, { verify_line = false })
			if code_link then
				code_link.physical_deleted = true
				code_link.physical_deleted_at = os.time()
				code_link.active = false
				store_link.update_code(id, code_link)

				local meta = require("todo2.store.meta")
				meta.update_link_active_status(id, "code", false)
			end
		end
		vim.notify(string.format("📦 跳过了 %d 个归档任务的TODO删除", #archived_ids), vim.log.levels.DEBUG)
	end

	if renderer and renderer.render_code_status then
		pcall(renderer.render_code_status, renderer, bufnr)
	end

	-- ⭐ 修复：触发事件时传递所有受影响的文件
	if #all_ids > 0 then
		for filepath, data in pairs(todo_by_file) do
			local todo_bufnr = vim.fn.bufnr(filepath)
			if todo_bufnr ~= -1 then
				local all_files = { filepath, vim.api.nvim_buf_get_name(bufnr) }
				save_and_trigger(todo_bufnr, "delete_code_link", data.ids, all_files)
			end
		end
	end

	autosave.request_save(bufnr)
end

---------------------------------------------------------------------
-- 修改：批量删除TODO链接
---------------------------------------------------------------------
--- @param ids string[]
--- @param opts table?
--- @return boolean
function M.batch_delete_todo_links(ids, opts)
	opts = opts or {}

	if not ids or #ids == 0 then
		return false
	end

	local active_ids = {}
	local archived_ids = {}
	local by_file = {}

	for _, id in ipairs(ids) do
		local todo_link = store_link.get_todo(id, { verify_line = false })
		if todo_link then
			if todo_link.status == "archived" then
				table.insert(archived_ids, id)
			else
				table.insert(active_ids, id)

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
	end

	for file, data in pairs(by_file) do
		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)

		if #data.lines > 0 then
			M.delete_lines(bufnr, data.lines)
		end

		for _, id in ipairs(data.ids) do
			local code_link = store_link.get_code(id, { verify_line = false })
			if code_link and code_link.context then
				code_link.context_valid = false
				code_link.context_deleted_at = os.time()
				store_link.update_code(id, code_link)
			end
		end

		if renderer and renderer.render_code_status then
			pcall(renderer.render_code_status, renderer, bufnr)
		end

		autosave.request_save(bufnr)

		-- ⭐ 修复：触发事件时传递文件列表
		save_and_trigger(bufnr, "batch_delete_code", data.ids, { file })
	end

	M.delete_store_records(active_ids)

	if opts.todo_bufnr and vim.api.nvim_buf_is_valid(opts.todo_bufnr) then
		if vim.api.nvim_buf_is_loaded(opts.todo_bufnr) and vim.bo[opts.todo_bufnr].modified then
			autosave.flush(opts.todo_bufnr)
		end

		-- ⭐ 修复：收集所有受影响的文件
		local all_files = {}
		for file, _ in pairs(by_file) do
			table.insert(all_files, file)
		end
		table.insert(all_files, vim.api.nvim_buf_get_name(opts.todo_bufnr))

		save_and_trigger(opts.todo_bufnr, "batch_delete_todo_links", active_ids, all_files)
	end

	local msg =
		string.format("已批量删除 %d 个任务（跳过了 %d 个归档任务）", #active_ids, #archived_ids)
	if ui and ui.show_notification then
		ui.show_notification(msg)
	else
		vim.notify(msg, vim.log.levels.INFO)
	end

	return true
end

---------------------------------------------------------------------
-- 归档专用
---------------------------------------------------------------------
--- @param id string
--- @return boolean
function M.archive_code_link(id)
	if not id or id == "" then
		return false
	end

	local link = store_link.get_code(id, { verify_line = false })
	if not link or not link.path or not link.line then
		return false
	end

	local bufnr = vim.fn.bufadd(link.path)
	vim.fn.bufload(bufnr)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if link.line < 1 or link.line > #lines then
		return false
	end

	local line_content = lines[link.line]
	if
		not line_content
		or not id_utils.contains_code_mark(line_content)
		or not id_utils.extract_id_from_code_mark(line_content) == id
	then
		return false
	end

	M.delete_lines(bufnr, { link.line })

	local updated_link = vim.deepcopy(link)
	updated_link.physical_deleted = true
	updated_link.physical_deleted_at = os.time()
	updated_link.archived = true
	updated_link.active = false
	store_link.update_code(id, updated_link)

	local meta = require("todo2.store.meta")
	meta.update_link_active_status(id, "code", false)

	if renderer and renderer.render_code_status then
		pcall(renderer.render_code_status, renderer, bufnr)
	end

	autosave.request_save(bufnr)
	save_and_trigger(bufnr, "archive_code_link", { id })

	vim.notify(
		string.format("📦 归档: 已物理删除代码标记 %s (存储记录保留)", id:sub(1, 6)),
		vim.log.levels.INFO
	)

	return true
end

return M
