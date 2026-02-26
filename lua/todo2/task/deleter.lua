-- lua/todo2/task/deleter.lua
--- @module todo2.task.deleter
--- @brief 双链删除管理模块（修复版：保护归档任务）
--- ⭐ 增强：添加上下文清理 + 归档任务保护

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local parser = require("todo2.core.parser")
local store_link = require("todo2.store.link")
local renderer = require("todo2.task.renderer")
local ui = require("todo2.ui")

---------------------------------------------------------------------
-- 辅助函数（内部使用）
---------------------------------------------------------------------
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
-- 核心函数 1：物理删除文件中的行
---------------------------------------------------------------------
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
		vim.api.nvim_buf_set_lines(bufnr, ln - 1, ln, false, {})
	end

	return #unique_lines
end

---------------------------------------------------------------------
-- 核心函数 2：从存储中删除链接记录
---------------------------------------------------------------------
function M.delete_store_records(ids)
	if not ids or #ids == 0 then
		return { deleted_todo = 0, deleted_code = 0 }
	end

	local result = { deleted_todo = 0, deleted_code = 0 }

	for _, id in ipairs(ids) do
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
function M.clear_render_cache(bufnr, rows)
	if not renderer or not bufnr or not rows or #rows == 0 then
		return
	end

	if renderer.invalidate_render_cache_for_lines then
		renderer.invalidate_render_cache_for_lines(bufnr, rows)
	end
end

---------------------------------------------------------------------
-- 辅助函数：获取选择范围
---------------------------------------------------------------------
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
-- ⭐ 修复：删除TODO文件中的任务行（增加归档保护）
---------------------------------------------------------------------
function M.delete_todo_task_line(id)
	local todo_link = store_link.get_todo(id, { verify_line = true })
	if not todo_link or not todo_link.path or not todo_link.line then
		return false
	end

	-- ⭐ 检查是否是归档任务
	if todo_link.status == "archived" then
		vim.notify(
			string.format("📦 归档任务 %s 仅从文件中移除，保留存储记录", id:sub(1, 6)),
			vim.log.levels.INFO
		)
		-- 只删除文件中的行，不删除存储
		local todo_bufnr = vim.fn.bufadd(todo_link.path)
		vim.fn.bufload(todo_bufnr)
		M.delete_lines(todo_bufnr, { todo_link.line })
		autosave.request_save(todo_bufnr)
		return true
	end

	-- 非归档任务：正常删除
	local todo_bufnr = vim.fn.bufadd(todo_link.path)
	vim.fn.bufload(todo_bufnr)

	local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)
	if todo_link.line < 1 or todo_link.line > #lines then
		return false
	end

	local line_content = lines[todo_link.line]
	if not line_content or not line_content:match(id) then
		return false
	end

	M.delete_lines(todo_bufnr, { todo_link.line })

	autosave.request_save(todo_bufnr)
	save_and_trigger(todo_bufnr, "delete_todo_task_line", { id })

	return true
end

function M.batch_delete_todo_task_lines(ids)
	if not ids or #ids == 0 then
		return 0
	end

	local success_count = 0
	local archived_count = 0

	for _, id in ipairs(ids) do
		local todo_link = store_link.get_todo(id, { verify_line = false })
		if todo_link and todo_link.status == "archived" then
			archived_count = archived_count + 1
			-- 归档任务：只删除文件中的行
			local todo_bufnr = vim.fn.bufadd(todo_link.path)
			vim.fn.bufload(todo_bufnr)
			M.delete_lines(todo_bufnr, { todo_link.line })
			autosave.request_save(todo_bufnr)
		elseif M.delete_todo_task_line(id) then
			success_count = success_count + 1
		end
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
-- ⭐ 修复：delete_code_link 函数（添加上下文清理 + 归档保护）
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

	for _, mark in ipairs(marked_lines) do
		for _, id in ipairs(mark.ids) do
			-- ⭐ 检查是否是归档任务
			local todo_link = store_link.get_todo(id, { verify_line = false })
			if todo_link and todo_link.status == "archived" then
				table.insert(archived_ids, id)
				vim.notify(
					string.format("📦 归档任务 %s 的代码标记跳过删除", id:sub(1, 6)),
					vim.log.levels.DEBUG
				)
			else
				table.insert(all_ids, id)
			end
		end
		table.insert(lines_to_delete, mark.lnum)
	end

	if #all_ids == 0 and #lines_to_delete > 0 then
		-- 只有归档任务，只删除文件行，不删除存储
		M.delete_lines(bufnr, lines_to_delete)
		autosave.request_save(bufnr)
		vim.notify("📦 只删除了代码文件中的行，归档任务的存储记录已保留", vim.log.levels.INFO)
		return
	end

	-- ⭐ 标记上下文为已删除（只对非归档任务）
	for _, id in ipairs(all_ids) do
		local code_link = store_link.get_code(id, { verify_line = false })
		if code_link and code_link.context then
			code_link.context_valid = false
			code_link.context_deleted_at = os.time()
			store_link.update_code(id, code_link)
		end
	end

	local rows_to_clear = {}
	for _, ln in ipairs(lines_to_delete) do
		table.insert(rows_to_clear, ln - 1)
	end
	M.clear_render_cache(bufnr, rows_to_clear)

	local deleted_count = M.delete_lines(bufnr, lines_to_delete)

	local todo_deleted_count = M.batch_delete_todo_task_lines(all_ids)

	M.delete_store_records(all_ids)

	if deleted_count > 0 or todo_deleted_count > 0 then
		autosave.request_save(bufnr)
		save_and_trigger(bufnr, "delete_code_link", all_ids)
	end
end

---------------------------------------------------------------------
-- ⭐ 修复：批量删除TODO链接（增加归档保护）
---------------------------------------------------------------------
function M.batch_delete_todo_links(ids, opts)
	opts = opts or {}

	if not ids or #ids == 0 then
		return
	end

	-- ⭐ 过滤掉归档任务
	local active_ids = {}
	local archived_ids = {}

	for _, id in ipairs(ids) do
		local todo_link = store_link.get_todo(id, { verify_line = false })
		if todo_link and todo_link.status == "archived" then
			table.insert(archived_ids, id)
		else
			table.insert(active_ids, id)
		end
	end

	if #archived_ids > 0 then
		vim.notify(string.format("📦 跳过了 %d 个归档任务的删除", #archived_ids), vim.log.levels.DEBUG)
	end

	if #active_ids == 0 then
		return
	end

	local code_links_by_file = {}

	for _, id in ipairs(active_ids) do
		local code_link = store_link.get_code(id, { verify_line = false })
		if code_link and code_link.path and code_link.line then
			local file = code_link.path
			if not code_links_by_file[file] then
				code_links_by_file[file] = {}
			end
			table.insert(code_links_by_file[file], {
				id = id,
				line = code_link.line,
			})
		end
	end

	for file, links in pairs(code_links_by_file) do
		table.sort(links, function(a, b)
			return a.line > b.line
		end)

		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)

		local rows_to_clear = {}
		for _, link in ipairs(links) do
			table.insert(rows_to_clear, link.line - 1)
		end
		M.clear_render_cache(bufnr, rows_to_clear)

		local lines_to_delete = {}
		local deleted_ids = {}
		for _, link in ipairs(links) do
			local line_content = vim.api.nvim_buf_get_lines(bufnr, link.line - 1, link.line, false)[1]
			if line_content and line_content:match(link.id) then
				table.insert(lines_to_delete, link.line)
				table.insert(deleted_ids, link.id)

				-- ⭐ 标记上下文为已删除
				local code_link = store_link.get_code(link.id, { verify_line = false })
				if code_link and code_link.context then
					code_link.context_valid = false
					code_link.context_deleted_at = os.time()
					store_link.update_code(link.id, code_link)
				end
			end
		end

		M.delete_lines(bufnr, lines_to_delete)

		if #deleted_ids > 0 then
			if renderer and renderer.render_code_status then
				pcall(renderer.render_code_status, bufnr)
			end

			autosave.request_save(bufnr)
			save_and_trigger(bufnr, "batch_delete_code", deleted_ids)
		end
	end

	M.delete_store_records(active_ids)

	if opts.todo_bufnr and vim.api.nvim_buf_is_valid(opts.todo_bufnr) then
		if vim.api.nvim_buf_is_loaded(opts.todo_bufnr) and vim.bo[opts.todo_bufnr].modified then
			autosave.flush(opts.todo_bufnr)
		end
		save_and_trigger(opts.todo_bufnr, "batch_delete_todo_links", active_ids)
	elseif opts.todo_file then
		local todo_bufnr = vim.fn.bufnr(opts.todo_file)
		if todo_bufnr ~= -1 and vim.api.nvim_buf_is_valid(todo_bufnr) then
			if vim.api.nvim_buf_is_loaded(todo_bufnr) and vim.bo[todo_bufnr].modified then
				autosave.flush(todo_bufnr)
			end
			save_and_trigger(todo_bufnr, "batch_delete_todo_links", active_ids)
		end
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
-- ⭐ 修复：TODO被删除 → 同步删除代码标记和存储（增加归档保护）
---------------------------------------------------------------------
function M.on_todo_deleted(id)
	if not id or id == "" then
		return
	end

	local todo_link = store_link.get_todo(id, { verify_line = true })
	if not todo_link then
		return
	end

	-- ⭐ 关键修复：检查是否是归档任务
	if todo_link.status == "archived" then
		-- 归档任务：只删除 TODO 文件中的行，保留代码标记和存储
		vim.notify(
			string.format("📦 归档任务 %s 从 TODO 文件中移除，代码标记保留", id:sub(1, 6)),
			vim.log.levels.INFO
		)

		-- 只删除 TODO 文件中的行
		local todo_bufnr = vim.fn.bufadd(todo_link.path)
		vim.fn.bufload(todo_bufnr)
		M.delete_lines(todo_bufnr, { todo_link.line })
		autosave.request_save(todo_bufnr)

		return -- ⭐ 直接返回，不删除代码标记和存储
	end

	-- 以下是原有逻辑（只处理非归档任务）
	if parser and parser.invalidate_cache then
		parser.invalidate_cache(todo_link.path)
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

	local code_links_by_file = {}
	for _, did in ipairs(all_ids) do
		local code_link = store_link.get_code(did, { verify_line = false })
		if code_link and code_link.path and code_link.line then
			if not code_links_by_file[code_link.path] then
				code_links_by_file[code_link.path] = {}
			end
			table.insert(code_links_by_file[code_link.path], {
				id = did,
				line = code_link.line,
			})
		end
	end

	-- 在删除代码标记前标记上下文为已删除
	for file, links in pairs(code_links_by_file) do
		for _, link_info in ipairs(links) do
			local code_link = store_link.get_code(link_info.id, { verify_line = false })
			if code_link and code_link.context then
				code_link.context_valid = false
				code_link.context_deleted_at = os.time()
				store_link.update_code(link_info.id, code_link)
			end
		end
	end

	for file, links in pairs(code_links_by_file) do
		table.sort(links, function(a, b)
			return a.line > b.line
		end)

		local code_bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(code_bufnr)

		local rows_to_clear = {}
		for _, link in ipairs(links) do
			table.insert(rows_to_clear, link.line - 1)
		end
		M.clear_render_cache(code_bufnr, rows_to_clear)

		local lines_to_delete = {}
		for _, link in ipairs(links) do
			local line_content = vim.api.nvim_buf_get_lines(code_bufnr, link.line - 1, link.line, false)[1]
			if line_content and line_content:match(link.id) then
				table.insert(lines_to_delete, link.line)
			end
		end
		M.delete_lines(code_bufnr, lines_to_delete)

		if renderer and renderer.render_code_status then
			pcall(renderer.render_code_status, code_bufnr)
		end

		autosave.request_save(code_bufnr)
		save_and_trigger(code_bufnr, "on_todo_deleted", all_ids)
	end

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
-- ⭐ 归档专用（保持不变）
---------------------------------------------------------------------
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
	if not line_content:match(id) then
		return false
	end

	-- 清理渲染缓存
	M.clear_render_cache(bufnr, { link.line - 1 })

	-- 物理删除行
	M.delete_lines(bufnr, { link.line })

	-- 更新链接状态并通知meta更新活跃状态
	local updated_link = vim.deepcopy(link)
	updated_link.physical_deleted = true
	updated_link.physical_deleted_at = os.time()
	updated_link.archived = true
	updated_link.active = false -- 标记为非活跃
	store_link.update_code(id, updated_link)

	-- 通知meta更新活跃计数
	local meta = require("todo2.store.meta")
	meta.update_link_active_status(id, "code", false)

	-- 重新渲染
	if renderer and renderer.render_code_status then
		pcall(renderer.render_code_status, bufnr)
	end

	-- 统一保存和触发事件
	autosave.request_save(bufnr)
	save_and_trigger(bufnr, "archive_code_link", { id })

	vim.notify(
		string.format("📦 归档: 已物理删除代码标记 %s (存储记录保留)", id:sub(1, 6)),
		vim.log.levels.INFO
	)

	return true
end

return M
