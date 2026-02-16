-- lua/todo2/link/deleter.lua
--- @module todo2.link.deleter
--- @brief 双链删除管理模块（修复版：正确维护元数据计数）

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local parser = require("todo2.core.parser")
local store_link = require("todo2.store.link")
local store_meta = require("todo2.store.meta") -- ⭐ 新增：直接引用meta
local renderer = require("todo2.link.renderer")
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

	-- 确保缓冲区已加载并且有修改，立即保存
	if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
		autosave.flush(bufnr)
	end

	-- 触发文件保存事件
	local save_event = {
		source = "deleter_save",
		file = vim.api.nvim_buf_get_name(bufnr),
		bufnr = bufnr,
	}

	if events and not events.is_event_processing(save_event) then
		events.on_state_changed(save_event)
	end

	-- 如果有指定source和ids，触发状态变更事件
	if source and ids and #ids > 0 then
		trigger_state_change(source, bufnr, ids)
	end
end

---------------------------------------------------------------------
-- ⭐ 核心函数 1：物理删除文件中的行
---------------------------------------------------------------------
--- 物理删除缓冲区中的指定行
--- @param bufnr number 缓冲区号
--- @param lines number[] 要删除的行号列表（1-based）
--- @return number 实际删除的行数
function M.delete_lines(bufnr, lines)
	if not bufnr or not lines or #lines == 0 then
		return 0
	end

	-- 去重并降序排序
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

	-- 删除行
	for _, ln in ipairs(unique_lines) do
		vim.api.nvim_buf_set_lines(bufnr, ln - 1, ln, false, {})
	end

	return #unique_lines
end

---------------------------------------------------------------------
-- ⭐ 核心函数 2：从存储中删除链接记录
---------------------------------------------------------------------
--- 批量从存储中删除链接记录
--- @param ids string[] ID列表
--- @return table {deleted_todo = number, deleted_code = number}
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
-- ⭐ 核心函数 3：清理渲染缓存
---------------------------------------------------------------------
--- 清理指定行的渲染缓存
--- @param bufnr number 缓冲区号
--- @param rows number[] 0-based行号列表
function M.clear_render_cache(bufnr, rows)
	if not renderer or not bufnr or not rows or #rows == 0 then
		return
	end

	if renderer.invalidate_render_cache_for_lines then
		renderer.invalidate_render_cache_for_lines(bufnr, rows)
	end
end

---------------------------------------------------------------------
-- ⭐ 辅助函数：获取选择范围
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
-- ⭐ 辅助函数：识别包含标记的行
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
-- ⭐ 辅助函数：查找子任务
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

	-- 收集子任务ID
	for i = todo_link.line + 1, #lines do
		local line = lines[i]
		local indent = line:match("^(%s*)") or ""

		-- 如果缩进级别减小或相同，停止搜索
		if #indent <= #parent_indent then
			break
		end

		-- 检查是否是任务行
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
-- ⭐ 新增：同步删除TODO文件中的任务行
---------------------------------------------------------------------
--- 根据ID删除TODO文件中的任务行
--- @param id string 任务ID
--- @return boolean 是否成功
function M.delete_todo_task_line(id)
	local todo_link = store_link.get_todo(id, { verify_line = true })
	if not todo_link or not todo_link.path or not todo_link.line then
		return false
	end

	local todo_bufnr = vim.fn.bufadd(todo_link.path)
	vim.fn.bufload(todo_bufnr)

	-- 检查行是否存在且包含正确的ID
	local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)
	if todo_link.line < 1 or todo_link.line > #lines then
		return false
	end

	local line_content = lines[todo_link.line]
	if not line_content or not line_content:match(id) then
		return false
	end

	-- 物理删除行
	M.delete_lines(todo_bufnr, { todo_link.line })

	-- 保存TODO文件
	autosave.request_save(todo_bufnr)

	-- 触发事件刷新TODO文件UI
	save_and_trigger(todo_bufnr, "delete_todo_task_line", { id })

	return true
end

--- 批量同步删除TODO文件中的任务行
--- @param ids string[] ID列表
--- @return number 成功删除的数量
function M.batch_delete_todo_task_lines(ids)
	if not ids or #ids == 0 then
		return 0
	end

	local success_count = 0

	for _, id in ipairs(ids) do
		if M.delete_todo_task_line(id) then
			success_count = success_count + 1
		end
	end

	return success_count
end

---------------------------------------------------------------------
-- ⭐ 修改：delete_code_link 函数（添加同步删除TODO任务）
---------------------------------------------------------------------
function M.delete_code_link(opts)
	opts = opts or {}
	local bufnr = vim.api.nvim_get_current_buf()

	-- 1. 获取删除范围
	local start_lnum, end_lnum = M._get_selection_range()

	-- 2. 识别包含标记的行
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)
	local marked_lines = M._identify_marked_lines(bufnr, lines, start_lnum)

	if #marked_lines == 0 then
		vim.notify("当前行/选区中没有找到任务标记", vim.log.levels.WARN)
		return
	end

	-- 3. 收集所有ID
	local all_ids = {}
	local lines_to_delete = {}
	for _, mark in ipairs(marked_lines) do
		for _, id in ipairs(mark.ids) do
			table.insert(all_ids, id)
		end
		table.insert(lines_to_delete, mark.lnum)
	end

	-- 4. 如果不是强制删除，显示预览并请求确认
	if not opts.force then
		local preview_lines = {}
		for i, mark in ipairs(marked_lines) do
			if i > 5 then
				table.insert(preview_lines, "... 还有 " .. (#marked_lines - 5) .. " 行")
				break
			end
			local preview = string.format("行 %d: %s", mark.lnum, mark.content:sub(1, 60))
			if #mark.content > 60 then
				preview = preview .. "..."
			end
			table.insert(preview_lines, preview)
		end
		local preview = table.concat(preview_lines, "\n")

		local msg = string.format(
			"将删除以下 %d 个任务标记行：\n\n%s\n\n确认删除吗？",
			#marked_lines,
			preview
		)
		local confirm = vim.fn.confirm(msg, "&确认\n&取消", 1)
		if confirm ~= 1 then
			vim.notify("已取消删除操作", vim.log.levels.INFO)
			return
		end
	end

	-- 5. 清理渲染缓存
	local rows_to_clear = {}
	for _, ln in ipairs(lines_to_delete) do
		table.insert(rows_to_clear, ln - 1)
	end
	M.clear_render_cache(bufnr, rows_to_clear)

	-- 6. 物理删除代码行
	local deleted_count = M.delete_lines(bufnr, lines_to_delete)

	-- ⭐ 7. 新增：同步删除TODO文件中的任务行
	local todo_deleted_count = M.batch_delete_todo_task_lines(all_ids)

	-- 8. 从存储中删除记录（会自动减少元数据计数）
	M.delete_store_records(all_ids)

	-- 9. 统一保存和触发事件
	if deleted_count > 0 or todo_deleted_count > 0 then
		autosave.request_save(bufnr)
		save_and_trigger(bufnr, "delete_code_link", all_ids)

		local msg = string.format(
			"✅ 已删除 %d 个代码标记行，%d 个TODO任务行",
			deleted_count,
			todo_deleted_count
		)
		vim.notify(msg, vim.log.levels.INFO)
	end
end

---------------------------------------------------------------------
-- ⭐ 业务函数 2：批量删除TODO链接（代码标记）
---------------------------------------------------------------------
function M.batch_delete_todo_links(ids, opts)
	opts = opts or {}

	if not ids or #ids == 0 then
		return
	end

	-- 按照文件分组，批量处理代码标记
	local code_links_by_file = {}

	-- 收集每个ID对应的代码链接
	for _, id in ipairs(ids) do
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

	-- 按文件分组删除代码标记
	for file, links in pairs(code_links_by_file) do
		-- 按行号降序排序
		table.sort(links, function(a, b)
			return a.line > b.line
		end)

		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)

		-- 清理渲染缓存
		local rows_to_clear = {}
		for _, link in ipairs(links) do
			table.insert(rows_to_clear, link.line - 1)
		end
		M.clear_render_cache(bufnr, rows_to_clear)

		-- 批量删除行
		local lines_to_delete = {}
		local deleted_ids = {}
		for _, link in ipairs(links) do
			local line_content = vim.api.nvim_buf_get_lines(bufnr, link.line - 1, link.line, false)[1]
			if line_content and line_content:match(link.id) then
				table.insert(lines_to_delete, link.line)
				table.insert(deleted_ids, link.id)
			end
		end

		-- 物理删除行
		M.delete_lines(bufnr, lines_to_delete)

		if #deleted_ids > 0 then
			-- 确保重新渲染整个缓冲区
			if renderer and renderer.render_code_status then
				pcall(renderer.render_code_status, bufnr)
			end

			-- 保存代码文件并触发事件
			autosave.request_save(bufnr)
			save_and_trigger(bufnr, "batch_delete_code", deleted_ids)
		end
	end

	-- 批量从存储中删除所有链接记录（会自动减少元数据计数）
	M.delete_store_records(ids)

	-- 保存TODO文件并触发事件
	if opts.todo_bufnr and vim.api.nvim_buf_is_valid(opts.todo_bufnr) then
		if vim.api.nvim_buf_is_loaded(opts.todo_bufnr) and vim.bo[opts.todo_bufnr].modified then
			autosave.flush(opts.todo_bufnr)
		end
		save_and_trigger(opts.todo_bufnr, "batch_delete_todo_links", ids)
	elseif opts.todo_file then
		local todo_bufnr = vim.fn.bufnr(opts.todo_file)
		if todo_bufnr ~= -1 and vim.api.nvim_buf_is_valid(todo_bufnr) then
			if vim.api.nvim_buf_is_loaded(todo_bufnr) and vim.bo[todo_bufnr].modified then
				autosave.flush(todo_bufnr)
			end
			save_and_trigger(todo_bufnr, "batch_delete_todo_links", ids)
		end
	end

	-- 显示通知
	local msg = string.format("已批量删除 %d 个任务", #ids)
	if ui and ui.show_notification then
		ui.show_notification(msg)
	else
		vim.notify(msg, vim.log.levels.INFO)
	end

	return true
end

---------------------------------------------------------------------
-- ⭐ 业务函数 3：TODO被删除 → 同步删除代码标记和存储
---------------------------------------------------------------------
function M.on_todo_deleted(id)
	if not id or id == "" then
		return
	end

	local todo_link = store_link.get_todo(id, { verify_line = true })
	if not todo_link then
		return
	end

	-- 清理解析树缓存
	if parser and parser.invalidate_cache then
		parser.invalidate_cache(todo_link.path)
	end

	-- 查找TODO文件缓冲区
	local todo_bufnr = vim.fn.bufnr(todo_link.path)
	if todo_bufnr == -1 then
		todo_bufnr = vim.fn.bufadd(todo_link.path)
		vim.fn.bufload(todo_bufnr)
	end

	-- 查找子任务
	local child_ids = {}
	if todo_bufnr ~= -1 and vim.api.nvim_buf_is_valid(todo_bufnr) then
		child_ids = M._find_child_tasks(id, todo_bufnr)
	end

	-- 合并所有ID
	local all_ids = { id }
	vim.list_extend(all_ids, child_ids)

	-- 收集所有需要删除的代码标记
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

	-- 批量删除代码标记
	for file, links in pairs(code_links_by_file) do
		table.sort(links, function(a, b)
			return a.line > b.line
		end)

		local code_bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(code_bufnr)

		-- 清理渲染缓存
		local rows_to_clear = {}
		for _, link in ipairs(links) do
			table.insert(rows_to_clear, link.line - 1)
		end
		M.clear_render_cache(code_bufnr, rows_to_clear)

		-- 删除行
		local lines_to_delete = {}
		for _, link in ipairs(links) do
			local line_content = vim.api.nvim_buf_get_lines(code_bufnr, link.line - 1, link.line, false)[1]
			if line_content and line_content:match(link.id) then
				table.insert(lines_to_delete, link.line)
			end
		end
		M.delete_lines(code_bufnr, lines_to_delete)

		-- 重新渲染
		if renderer and renderer.render_code_status then
			pcall(renderer.render_code_status, code_bufnr)
		end

		-- 保存并触发事件
		autosave.request_save(code_bufnr)
		save_and_trigger(code_bufnr, "on_todo_deleted", all_ids)
	end

	-- 批量从存储中删除所有链接记录（会自动减少元数据计数）
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
-- ⭐ 业务函数 4：归档专用（只删除物理代码标记，保留存储）
--    修复版：正确维护元数据计数
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

	-- 检查该行是否真的包含这个ID
	local line_content = lines[link.line]
	if not line_content:match(id) then
		vim.notify(string.format("警告：行 %d 不包含标记 %s", link.line, id), vim.log.levels.WARN)
		return false
	end

	-- 清理渲染缓存
	M.clear_render_cache(bufnr, { link.line - 1 })

	-- 物理删除行（只删除这一行）
	M.delete_lines(bufnr, { link.line })

	-- ⭐ 关键修复：标记存储记录为"已归档但不活跃"
	-- 不删除存储记录，但添加标记表明物理标记已不存在
	local updated_link = vim.deepcopy(link)
	updated_link.physical_deleted = true
	updated_link.physical_deleted_at = os.time()
	updated_link.archived = true -- 确保归档状态
	store_link.update_code(id, updated_link)

	-- ⭐ 重要：不调用 decrement_links！因为存储记录还在
	-- 元数据计数应该保持不变，因为存储记录仍存在

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

-- 为了兼容性，保留原有的函数名别名
M.delete_code_link_by_id = M.delete_code_link -- 但实际不推荐使用

return M
