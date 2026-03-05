-- lua/todo2/task/deleter.lua
-- 优化版：去除冗余，合并重复逻辑，通过事件系统统一渲染

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local store_link = require("todo2.store.link")
local id_utils = require("todo2.utils.id")
local ui = require("todo2.ui")

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

-- ⭐ 文件内容缓存
local file_cache = {}
local CACHE_TTL = 1000 -- 1秒缓存

---------------------------------------------------------------------
-- ⭐ 统一代码标记验证函数
---------------------------------------------------------------------
--- 验证代码标记是否存在且ID匹配
--- @param filepath string
--- @param line_num number
--- @param expected_id string
--- @return boolean exists, string? warning
local function verify_code_mark(filepath, line_num, expected_id)
	if not filepath or vim.fn.filereadable(filepath) ~= 1 then
		return false, "文件不存在"
	end

	-- 使用缓存读取文件内容
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
		file_cache[cache_key] = {
			content = line_content,
			time = vim.loop.now(),
		}
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
-- ⭐ 清理文件缓存
---------------------------------------------------------------------
local function clear_file_cache(filepath)
	for key, _ in pairs(file_cache) do
		if key:find(filepath, 1, true) then
			file_cache[key] = nil
		end
	end
end

---------------------------------------------------------------------
-- 辅助函数（内部使用）
---------------------------------------------------------------------
--- @param source string
--- @param bufnr number
--- @param ids string[]
--- @param files? string[]
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
		trigger_state_change(source, bufnr, ids, files)
	end
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
-- 识别包含标记的行
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
-- 删除TODO任务行
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
			local exists, _ = verify_code_mark(code_link.path, code_link.line, id)
			if exists then
				local code_bufnr = vim.fn.bufadd(code_link.path)
				vim.fn.bufload(code_bufnr)
				M.delete_lines(code_bufnr, { code_link.line })
				autosave.request_save(code_bufnr)
			end
		end

		local status_mod = require("todo2.store.link.status")
		status_mod.mark_deleted(id, "archived_task_cleanup")
		autosave.request_save(todo_bufnr)
		return true
	end

	-- 添加到批处理队列
	if not batch_operations[todo_bufnr] then
		batch_operations[todo_bufnr] = { ids = {}, archived_ids = {}, lines_to_delete = {} }
	end
	batch_operations[todo_bufnr].ids[id] = true

	return true
end

---------------------------------------------------------------------
-- ⭐ 统一处理批量操作
---------------------------------------------------------------------
local function process_batch_operations()
	if vim.tbl_isempty(batch_operations) then
		return
	end

	local operations = vim.deepcopy(batch_operations)
	batch_operations = {}

	for bufnr, data in pairs(operations) do
		local active_ids = {}
		for id, _ in pairs(data.ids or {}) do
			table.insert(active_ids, id)
		end

		local archived_ids = {}
		for id, _ in pairs(data.archived_ids or {}) do
			table.insert(archived_ids, id)
		end

		if #active_ids > 0 then
			-- 收集受影响的TODO文件
			local todo_files = {}
			for _, id in ipairs(active_ids) do
				local todo_link = store_link.get_todo(id, { verify_line = false })
				if todo_link and todo_link.path and not vim.tbl_contains(todo_files, todo_link.path) then
					table.insert(todo_files, todo_link.path)
				end

				-- ⭐ 同时收集代码文件
				local code_link = store_link.get_code(id, { verify_line = false })
				if code_link and code_link.path and not vim.tbl_contains(todo_files, code_link.path) then
					table.insert(todo_files, code_link.path)
				end
			end

			-- 批量标记上下文为已删除
			for _, id in ipairs(active_ids) do
				local code_link = store_link.get_code(id, { verify_line = false })
				if code_link and code_link.context then
					code_link.context_valid = false
					code_link.context_deleted_at = os.time()
					store_link.update_code(id, code_link)
				end
			end

			-- 删除存储记录
			M.delete_store_records(active_ids)

			-- ⭐ 触发事件（让事件系统统一渲染）
			local all_files = { vim.api.nvim_buf_get_name(bufnr) }
			for _, file in ipairs(todo_files) do
				if not vim.tbl_contains(all_files, file) then
					table.insert(all_files, file)
				end
			end
			save_and_trigger(bufnr, "batch_delete", active_ids, all_files)
		end

		if #archived_ids > 0 then
			vim.notify(
				string.format("📦 跳过了 %d 个归档任务的存储删除", #archived_ids),
				vim.log.levels.DEBUG
			)
		end
	end

	if batch_timer then
		batch_timer:stop()
		batch_timer:close()
		batch_timer = nil
	end
end

---------------------------------------------------------------------
-- 从代码侧删除标记
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

	local all_ids = {}
	local archived_ids = {}
	local lines_to_delete = {}
	local lines_to_keep = {}
	local skipped_ids = {}

	local todo_by_file = {}

	for _, mark in ipairs(marked_lines) do
		local has_valid_code_mark = false
		local mark_ids = {}

		for _, id in ipairs(mark.ids) do
			-- 验证代码标记
			local exists, warning = verify_code_mark(vim.api.nvim_buf_get_name(bufnr), mark.lnum, id)

			if exists then
				has_valid_code_mark = true
				table.insert(mark_ids, id)
			else
				table.insert(skipped_ids, id)
				vim.notify(
					string.format("⚠️ 代码标记 %s 不存在，跳过物理删除", id:sub(1, 6)),
					vim.log.levels.WARN
				)
			end

			-- 检查对应的 todo 链接
			local todo_link = store_link.get_todo(id, { verify_line = false })
			if todo_link and todo_link.path and todo_link.line then
				if todo_link.status == "archived" then
					table.insert(archived_ids, id)
				elseif exists then
					table.insert(all_ids, id)

					if not todo_by_file[todo_link.path] then
						todo_by_file[todo_link.path] = { ids = {}, todo_lines = {} }
					end
					table.insert(todo_by_file[todo_link.path].ids, id)
					todo_by_file[todo_link.path].todo_lines[todo_link.line] = true
				end
			end
		end

		if has_valid_code_mark and #mark_ids > 0 then
			table.insert(lines_to_delete, mark.lnum)
		else
			table.insert(lines_to_keep, mark.lnum)
		end
	end

	-- 提示保留的行
	if #lines_to_keep > 0 then
		vim.notify(
			string.format("ℹ️ 保留了 %d 行（代码标记不存在）", #lines_to_keep),
			vim.log.levels.INFO
		)
	end

	-- 删除验证通过的代码行
	if #lines_to_delete > 0 then
		M.delete_lines(bufnr, lines_to_delete)
		clear_file_cache(vim.api.nvim_buf_get_name(bufnr))
	end

	-- 处理 TODO 文件
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
		clear_file_cache(filepath)

		local parser = require("todo2.core.parser")
		parser.invalidate_cache(filepath)

		autosave.request_save(todo_bufnr)
	end

	-- 删除存储记录
	if #all_ids > 0 then
		M.delete_store_records(all_ids)
	end

	-- 处理归档任务
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

	-- ⭐ 删除所有手动渲染代码，只触发事件
	if #all_ids > 0 then
		local affected_files = { vim.api.nvim_buf_get_name(bufnr) }
		for filepath, _ in pairs(todo_by_file) do
			if not vim.tbl_contains(affected_files, filepath) then
				table.insert(affected_files, filepath)
			end
		end

		-- 触发事件（让事件系统统一渲染）
		save_and_trigger(bufnr, "delete_code_link", all_ids, affected_files)
	end

	-- 汇总报告
	if #skipped_ids > 0 then
		vim.notify(
			string.format(
				"✅ 删除完成：删除了 %d 个代码标记，跳过了 %d 个不存在的标记",
				#lines_to_delete,
				#skipped_ids
			),
			vim.log.levels.INFO
		)
	end

	autosave.request_save(bufnr)
end

---------------------------------------------------------------------
-- 批量删除TODO链接
---------------------------------------------------------------------
function M.batch_delete_todo_links(ids, opts)
	opts = opts or {}

	if not ids or #ids == 0 then
		return false
	end

	local active_ids = {}
	local archived_ids = {}
	local by_file = {}
	local skipped_ids = {}

	for _, id in ipairs(ids) do
		local todo_link = store_link.get_todo(id, { verify_line = false })
		if todo_link then
			if todo_link.status == "archived" then
				table.insert(archived_ids, id)
			else
				local code_link = store_link.get_code(id, { verify_line = false })
				local should_delete_code = true
				local warning_msg = nil

				if code_link and code_link.path and code_link.line then
					local exists, msg = verify_code_mark(code_link.path, code_link.line, id)
					should_delete_code = exists
					warning_msg = msg
				end

				if should_delete_code and code_link and code_link.path then
					if not by_file[code_link.path] then
						by_file[code_link.path] = { ids = {}, lines = {} }
					end
					table.insert(by_file[code_link.path].ids, id)
					if code_link.line then
						table.insert(by_file[code_link.path].lines, code_link.line)
					end
					table.insert(active_ids, id)
				else
					table.insert(skipped_ids, id)
					if warning_msg then
						vim.notify(
							string.format(
								"⚠️ 代码标记 %s 不存在于 %s:%d，跳过物理删除",
								id:sub(1, 6),
								code_link and vim.fn.fnamemodify(code_link.path, ":t") or "?",
								code_link and code_link.line or 0
							),
							vim.log.levels.WARN
						)
					end
					table.insert(active_ids, id) -- 仍然删除存储记录
				end
			end
		end
	end

	-- 处理需要删除代码行的文件
	for file, data in pairs(by_file) do
		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)

		if #data.lines > 0 then
			local lines_to_delete = {}
			local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

			for _, line_num in ipairs(data.lines) do
				if line_num >= 1 and line_num <= #current_lines then
					local exists, _ = verify_code_mark(file, line_num, data.ids[1])
					if exists then
						table.insert(lines_to_delete, line_num)
					else
						vim.notify(
							string.format("⚠️ 行 %d 不是预期的代码标记，跳过删除", line_num),
							vim.log.levels.WARN
						)
					end
				end
			end

			if #lines_to_delete > 0 then
				M.delete_lines(bufnr, lines_to_delete)
				clear_file_cache(file)
			end
		end

		for _, id in ipairs(data.ids) do
			local code_link = store_link.get_code(id, { verify_line = false })
			if code_link and code_link.context then
				code_link.context_valid = false
				code_link.context_deleted_at = os.time()
				store_link.update_code(id, code_link)
			end
		end

		-- ⭐ 删除手动渲染，只触发事件
		autosave.request_save(bufnr)
		save_and_trigger(bufnr, "batch_delete_code", data.ids, { file })
	end

	-- 删除存储记录
	if #active_ids > 0 then
		M.delete_store_records(active_ids)
	end

	if opts.todo_bufnr and vim.api.nvim_buf_is_valid(opts.todo_bufnr) then
		if vim.api.nvim_buf_is_loaded(opts.todo_bufnr) and vim.bo[opts.todo_bufnr].modified then
			autosave.flush(opts.todo_bufnr)
		end

		local all_files = {}
		for file, _ in pairs(by_file) do
			table.insert(all_files, file)
		end
		table.insert(all_files, vim.api.nvim_buf_get_name(opts.todo_bufnr))

		save_and_trigger(opts.todo_bufnr, "batch_delete_todo_links", active_ids, all_files)
	end

	-- 汇总报告
	local msg_parts = {}
	table.insert(msg_parts, string.format("已删除 %d 个任务", #active_ids))
	if #skipped_ids > 0 then
		table.insert(msg_parts, string.format("(其中 %d 个跳过代码行删除)", #skipped_ids))
	end
	if #archived_ids > 0 then
		table.insert(msg_parts, string.format("跳过了 %d 个归档任务", #archived_ids))
	end

	local msg = table.concat(msg_parts, "，")
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
function M.archive_code_link(id)
	if not id or id == "" then
		return false
	end

	local link = store_link.get_code(id, { verify_line = false })
	if not link or not link.path or not link.line then
		return false
	end

	local exists, _ = verify_code_mark(link.path, link.line, id)
	if not exists then
		return false
	end

	local bufnr = vim.fn.bufadd(link.path)
	vim.fn.bufload(bufnr)

	M.delete_lines(bufnr, { link.line })
	clear_file_cache(link.path)

	local updated_link = vim.deepcopy(link)
	updated_link.physical_deleted = true
	updated_link.physical_deleted_at = os.time()
	updated_link.archived = true
	updated_link.active = false
	store_link.update_code(id, updated_link)

	local meta = require("todo2.store.meta")
	meta.update_link_active_status(id, "code", false)

	-- ⭐ 删除手动渲染，只触发事件
	autosave.request_save(bufnr)
	save_and_trigger(bufnr, "archive_code_link", { id })

	vim.notify(
		string.format("📦 归档: 已物理删除代码标记 %s (存储记录保留)", id:sub(1, 6)),
		vim.log.levels.INFO
	)

	return true
end

return M
