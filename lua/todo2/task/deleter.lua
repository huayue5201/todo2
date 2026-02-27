-- lua/todo2/task/deleter.lua
--- @module todo2.task.deleter
--- @brief 双链删除管理模块（优化版：批量操作 + 归档保护）
--- @diagnostic disable: undefined-global, need-check-nil

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local parser = require("todo2.core.parser")
local store_link = require("todo2.store.link")
local renderer = require("todo2.render.code_render")
local ui = require("todo2.ui")

---------------------------------------------------------------------
-- ⭐ 类型定义
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
-- ⭐ 批量操作状态
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
local function trigger_state_change(source, bufnr, ids)
	if #ids == 0 then
		return
	end

	local event_data = {
		source = source,
		file = vim.api.nvim_buf_get_name(bufnr),
		bufnr = bufnr,
		ids = ids,
	}

	if not events.is_event_processing(event_data) then
		events.on_state_changed(event_data)
	end
end

--- @param bufnr number
--- @param source string?
--- @param ids string[]?
local function save_and_trigger(bufnr, source, ids)
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
		trigger_state_change(source, bufnr, ids)
	end
end

---------------------------------------------------------------------
-- ⭐ 新增：执行批量删除（内部函数）
---------------------------------------------------------------------
--- @param bufnr number
--- @param active_ids string[]
--- @param archived_ids string[]
--- @param lines_to_delete number[]?
local function execute_batch_delete(bufnr, active_ids, archived_ids, lines_to_delete)
	-- 1. 批量删除文件行
	if lines_to_delete and #lines_to_delete > 0 then
		M.delete_lines(bufnr, lines_to_delete)
	end

	-- 2. 处理非归档任务
	if #active_ids > 0 then
		-- 批量标记上下文为已删除
		--- @type table<string, any>
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

		-- 批量触发事件
		save_and_trigger(bufnr, "batch_delete", active_ids)
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
-- ⭐ 修改：处理批量删除操作（修复3 - 立即执行）
---------------------------------------------------------------------
local function process_batch_operations()
	if vim.tbl_isempty(batch_operations) then
		return
	end

	--- @type table<number, BatchOperationData>
	local operations_to_process = vim.deepcopy(batch_operations)

	-- ⭐ 立即清空，不等待
	batch_operations = {}

	for bufnr, data in pairs(operations_to_process) do
		--- @type string[]
		local active_ids = {}
		for id, _ in pairs(data.ids or {}) do
			table.insert(active_ids, id)
		end

		--- @type string[]
		local archived_ids = {}
		for id, _ in pairs(data.archived_ids or {}) do
			table.insert(archived_ids, id)
		end

		if #active_ids > 0 or #archived_ids > 0 then
			-- 执行批量删除
			execute_batch_delete(bufnr, active_ids, archived_ids, data.lines_to_delete)
		end
	end

	-- 安全关闭定时器
	if batch_timer then
		batch_timer:stop()
		batch_timer:close()
		batch_timer = nil
	end
end

---------------------------------------------------------------------
-- ⭐ 修改：批量添加到批处理队列（修复3 - 立即执行）
---------------------------------------------------------------------
--- @param bufnr number
--- @param ids string[]
--- @param operation_type string?
local function add_to_batch(bufnr, ids, operation_type)
	if not ids or #ids == 0 then
		return
	end

	if not batch_operations[bufnr] then
		--- @type BatchOperationData
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

	-- ⭐ 立即处理，不等待延迟
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

	--- @type number[]
	local unique_lines = {}
	--- @type table<number, boolean>
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
		-- ⭐ 检查是否有快照，如果有则警告但不阻止删除
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
-- 核心函数 3：清理渲染缓存
---------------------------------------------------------------------
--- @param bufnr number
--- @param rows number[]
function M.clear_render_cache(bufnr, rows)
	if not renderer or not bufnr or not rows or #rows == 0 then
		return
	end

	if renderer.invalidate_render_cache_for_lines then
		local ok, err = pcall(renderer.invalidate_render_cache_for_lines, renderer, bufnr, rows)
		if not ok then
			vim.notify("清理渲染缓存失败: " .. tostring(err), vim.log.levels.DEBUG)
		end
	end
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
-- 辅助函数：识别包含标记的行
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

		for id in line:gmatch("[A-Z][A-Z0-9_]*:ref:(%w+)") do
			table.insert(ids, id)
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
-- 辅助函数：查找子任务
---------------------------------------------------------------------
--- @param parent_id string
--- @param todo_bufnr number
--- @return string[]
function M._find_child_tasks(parent_id, todo_bufnr)
	local child_ids = {}

	if not todo_bufnr or not vim.api.nvim_buf_is_valid(todo_bufnr) then
		return child_ids
	end

	local todo_link = store_link.get_todo(parent_id, { verify_line = true })
	if not todo_link or not todo_link.line then
		return child_ids
	end

	local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)
	local parent_line = lines[todo_link.line]
	if not parent_line then
		return child_ids
	end

	local parent_indent = parent_line:match("^(%s*)") or ""

	for i = todo_link.line + 1, #lines do
		local line = lines[i]
		local indent = line:match("^(%s*)") or ""

		if #indent <= #parent_indent then
			break
		end

		if line:match("^%s*[%-%*+]%s+%[[ xX>]%]") then
			local child_id = line:match("{#(%w+)}")
			if child_id then
				table.insert(child_ids, child_id)
			end
		end
	end

	return child_ids
end

---------------------------------------------------------------------
-- ⭐ 修改：删除TODO任务行（修复2 - 归档任务处理）
---------------------------------------------------------------------
--- @param id string
--- @return boolean
function M.delete_todo_task_line(id)
	local todo_link = store_link.get_todo(id, { verify_line = true })
	if not todo_link then
		return false
	end

	-- 获取代码链接
	local code_link = store_link.get_code(id, { verify_line = false })

	-- 获取 TODO 文件 buffer
	local todo_bufnr = vim.fn.bufadd(todo_link.path)
	vim.fn.bufload(todo_bufnr)

	-- 验证行仍然存在
	local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)
	if todo_link.line < 1 or todo_link.line > #lines then
		return false
	end

	local line_content = lines[todo_link.line]
	if not line_content or not line_content:match(id) then
		return false
	end

	-- 物理删除 TODO 行
	M.delete_lines(todo_bufnr, { todo_link.line })

	-- ⭐ 处理归档任务
	if todo_link.status == "archived" then
		-- 归档任务：同时删除代码标记（如果存在）
		if code_link and code_link.path and code_link.line then
			local code_bufnr = vim.fn.bufadd(code_link.path)
			vim.fn.bufload(code_bufnr)

			local code_lines = vim.api.nvim_buf_get_lines(code_bufnr, 0, -1, false)
			if code_link.line >= 1 and code_link.line <= #code_lines then
				local code_line = code_lines[code_link.line]
				if code_line and code_line:match(id) then
					M.delete_lines(code_bufnr, { code_link.line })
					M.clear_render_cache(code_bufnr, { code_link.line - 1 })
					autosave.request_save(code_bufnr)
				end
			end
		end

		-- 使用统一的软删除函数
		local status_mod = require("todo2.store.link.status")
		status_mod.mark_deleted(id, "archived_task_cleanup")

		autosave.request_save(todo_bufnr)
		return true
	end

	-- 非归档任务：添加到批处理
	add_to_batch(todo_bufnr, { id })
	return true
end

---------------------------------------------------------------------
-- 优化版：批量删除TODO任务行
---------------------------------------------------------------------
--- @param ids string[]
--- @return number
function M.batch_delete_todo_task_lines(ids)
	if not ids or #ids == 0 then
		return 0
	end

	local success_count = 0
	local archived_count = 0
	--- @type table<string, FileGroupData>
	local by_file = {}

	-- 按文件分组收集
	for _, id in ipairs(ids) do
		local todo_link = store_link.get_todo(id, { verify_line = false })
		if todo_link then
			if todo_link.status == "archived" then
				archived_count = archived_count + 1
			end

			if not by_file[todo_link.path] then
				by_file[todo_link.path] = { ids = {}, lines = {} }
			end
			table.insert(by_file[todo_link.path].ids, id)
			if todo_link.line then
				table.insert(by_file[todo_link.path].lines, todo_link.line)
			end
			success_count = success_count + 1
		end
	end

	-- 按文件批量处理
	for filepath, data in pairs(by_file) do
		local bufnr = vim.fn.bufadd(filepath)
		vim.fn.bufload(bufnr)

		-- 批量删除行
		M.delete_lines(bufnr, data.lines)

		-- 添加到批处理队列
		add_to_batch(bufnr, data.ids)
	end

	if archived_count > 0 then
		vim.notify(
			string.format("📦 跳过了 %d 个归档任务的存储删除", archived_count),
			vim.log.levels.DEBUG
		)
	end

	return success_count
end

---------------------------------------------------------------------
-- 优化版：delete_code_link
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

	for _, mark in ipairs(marked_lines) do
		for _, id in ipairs(mark.ids) do
			local todo_link = store_link.get_todo(id, { verify_line = false })
			if todo_link and todo_link.status == "archived" then
				table.insert(archived_ids, id)
			else
				table.insert(all_ids, id)
			end
		end
		table.insert(lines_to_delete, mark.lnum)
	end

	-- 批量添加到队列
	if #lines_to_delete > 0 then
		if not batch_operations[bufnr] then
			--- @type BatchOperationData
			batch_operations[bufnr] = { ids = {}, lines_to_delete = {} }
		end
		for _, ln in ipairs(lines_to_delete) do
			table.insert(batch_operations[bufnr].lines_to_delete, ln)
		end
		for _, id in ipairs(all_ids) do
			batch_operations[bufnr].ids[id] = true
		end

		-- 启动批处理
		add_to_batch(bufnr, all_ids)
	end

	if #archived_ids > 0 then
		vim.notify(
			string.format("📦 跳过了 %d 个归档任务的存储删除", #archived_ids),
			vim.log.levels.DEBUG
		)
	end
end

---------------------------------------------------------------------
-- 优化版：批量删除TODO链接
---------------------------------------------------------------------
--- @param ids string[]
--- @param opts table?
--- @return boolean
function M.batch_delete_todo_links(ids, opts)
	opts = opts or {}

	if not ids or #ids == 0 then
		return false
	end

	-- 过滤归档任务
	local active_ids = {}
	local archived_ids = {}
	--- @type table<string, FileGroupData>
	local by_file = {}

	for _, id in ipairs(ids) do
		local todo_link = store_link.get_todo(id, { verify_line = false })
		if todo_link then
			if todo_link.status == "archived" then
				table.insert(archived_ids, id)
			else
				table.insert(active_ids, id)

				-- 收集对应的代码链接
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

	-- 按文件批量处理代码标记
	for file, data in pairs(by_file) do
		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)

		-- 批量删除行
		if #data.lines > 0 then
			M.delete_lines(bufnr, data.lines)
		end

		-- 批量标记上下文
		for _, id in ipairs(data.ids) do
			local code_link = store_link.get_code(id, { verify_line = false })
			if code_link and code_link.context then
				code_link.context_valid = false
				code_link.context_deleted_at = os.time()
				store_link.update_code(id, code_link)
			end
		end

		-- 重新渲染
		if renderer and renderer.render_code_status then
			pcall(renderer.render_code_status, renderer, bufnr)
		end

		autosave.request_save(bufnr)
		save_and_trigger(bufnr, "batch_delete_code", data.ids)
	end

	-- 批量删除存储记录
	M.delete_store_records(active_ids)

	-- 触发TODO文件保存
	if opts.todo_bufnr and vim.api.nvim_buf_is_valid(opts.todo_bufnr) then
		if vim.api.nvim_buf_is_loaded(opts.todo_bufnr) and vim.bo[opts.todo_bufnr].modified then
			autosave.flush(opts.todo_bufnr)
		end
		save_and_trigger(opts.todo_bufnr, "batch_delete_todo_links", active_ids)
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
-- 优化版：TODO被删除 → 同步删除代码标记和存储
---------------------------------------------------------------------
--- @param id string
function M.on_todo_deleted(id)
	if not id or id == "" then
		return
	end

	local todo_link = store_link.get_todo(id, { verify_line = true })
	if not todo_link then
		return
	end

	-- 检查是否是归档任务
	if todo_link.status == "archived" then
		vim.notify(
			string.format("📦 归档任务 %s 从 TODO 文件中移除，代码标记保留", id:sub(1, 6)),
			vim.log.levels.INFO
		)
		local todo_bufnr = vim.fn.bufadd(todo_link.path)
		vim.fn.bufload(todo_bufnr)
		M.delete_lines(todo_bufnr, { todo_link.line })
		autosave.request_save(todo_bufnr)
		return
	end

	-- 非归档任务：查找所有子任务
	if parser and parser.invalidate_cache then
		parser.invalidate_cache(parser, todo_link.path)
	end

	local todo_bufnr = vim.fn.bufnr(todo_link.path)
	if todo_bufnr == -1 then
		todo_bufnr = vim.fn.bufadd(todo_link.path)
		vim.fn.bufload(todo_bufnr)
	end

	local child_ids = {}
	if todo_bufnr ~= -1 and vim.api.nvim_buf_is_valid(todo_bufnr) then
		child_ids = M._find_child_tasks(id, todo_bufnr)
	end

	local all_ids = { id }
	vim.list_extend(all_ids, child_ids)

	-- 按文件分组收集代码链接
	--- @type table<string, FileGroupData>
	local by_file = {}
	for _, did in ipairs(all_ids) do
		local code_link = store_link.get_code(did, { verify_line = false })
		if code_link and code_link.path and code_link.line then
			if not by_file[code_link.path] then
				by_file[code_link.path] = { ids = {}, lines = {} }
			end
			table.insert(by_file[code_link.path].ids, did)
			table.insert(by_file[code_link.path].lines, code_link.line)

			-- 标记上下文为已删除
			if code_link.context then
				code_link.context_valid = false
				code_link.context_deleted_at = os.time()
				store_link.update_code(did, code_link)
			end
		end
	end

	-- 按文件批量删除
	for file, data in pairs(by_file) do
		local code_bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(code_bufnr)

		local rows_to_clear = {}
		for _, line in ipairs(data.lines) do
			table.insert(rows_to_clear, line - 1)
		end
		M.clear_render_cache(code_bufnr, rows_to_clear)

		-- 批量删除行
		M.delete_lines(code_bufnr, data.lines)

		if renderer and renderer.render_code_status then
			pcall(renderer.render_code_status, renderer, code_bufnr)
		end

		autosave.request_save(code_bufnr)
		save_and_trigger(code_bufnr, "on_todo_deleted", data.ids)
	end

	-- 批量删除存储记录
	M.delete_store_records(all_ids)

	if ui and ui.show_notification then
		ui.show_notification(
			string.format("已同步删除标记 %s 及其子任务的代码与存储记录", id:sub(1, 6))
		)
	else
		vim.notify(
			string.format("已同步删除标记 %s 及其子任务的代码与存储记录", id:sub(1, 6)),
			vim.log.levels.INFO
		)
	end
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
	if not line_content or not line_content:match(id) then
		return false
	end

	-- 清理渲染缓存
	M.clear_render_cache(bufnr, { link.line - 1 })

	-- 物理删除行
	M.delete_lines(bufnr, { link.line })

	-- 更新链接状态
	local updated_link = vim.deepcopy(link)
	updated_link.physical_deleted = true
	updated_link.physical_deleted_at = os.time()
	updated_link.archived = true
	updated_link.active = false
	store_link.update_code(id, updated_link)

	-- 通知meta更新活跃计数
	local meta = require("todo2.store.meta")
	meta.update_link_active_status(id, "code", false)

	-- 重新渲染
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
