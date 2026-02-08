-- lua/todo2/link/deleter.lua
--- @module todo2.link.deleter
--- @brief 双链删除管理模块（修复归档相关逻辑）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 辅助函数（保持不变）
---------------------------------------------------------------------
local function trigger_state_change(source, bufnr, ids)
	if #ids == 0 then
		return
	end

	local events = module.get("core.events")
	local event_data = {
		source = source,
		file = vim.api.nvim_buf_get_name(bufnr),
		bufnr = bufnr,
		ids = ids,
	}

	-- 检查是否已经有相同的事件在处理中
	if not events.is_event_processing(event_data) then
		events.on_state_changed(event_data)
	end
end

local function request_autosave(bufnr)
	local autosave = module.get("core.autosave")
	-- 只保存，不触发事件
	autosave.request_save(bufnr)
end

local function delete_buffer_lines(bufnr, start_line, end_line)
	local count = end_line - start_line + 1
	vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, {})
	return count
end

---------------------------------------------------------------------
-- 删除代码文件中的标记行（修复存储API调用）
---------------------------------------------------------------------
function M.delete_code_link_by_id(id)
	if not id or id == "" then
		return false
	end

	-- ⭐ 修复：使用正确的存储模块API
	local store_link = module.get("store.link")

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

	delete_buffer_lines(bufnr, link.line, link.line)

	-- 自动保存 + 事件驱动刷新
	request_autosave(bufnr)
	trigger_state_change("delete_code_link_by_id", bufnr, { id })

	return true
end

---------------------------------------------------------------------
-- 删除 store 中的记录（修复存储API调用）
---------------------------------------------------------------------
--- 删除存储中的链接记录
--- @param id string 链接ID
--- @return boolean 是否删除了任何链接
function M.delete_store_links_by_id(id)
	if not id or id == "" then
		return false
	end

	local store_link = module.get("store.link")
	if not store_link then
		return false
	end

	local had_todo = store_link.delete_todo(id)
	local had_code = store_link.delete_code(id)

	return had_todo or had_code
end

---------------------------------------------------------------------
-- TODO 被删除 → 同步删除代码 + store（修复存储API调用）
---------------------------------------------------------------------
function M.on_todo_deleted(id)
	if not id or id == "" then
		return
	end

	-- ⭐ 修复：使用正确的存储模块API
	local store_link = module.get("store.link")

	local todo_link = store_link.get_todo(id, { verify_line = true })

	-- ⭐ 关键修复：清理解析树缓存
	if todo_link and todo_link.path then
		local parser = module.get("core.parser")
		if parser and parser.invalidate_cache then
			parser.invalidate_cache(todo_link.path)
		end

		-- 查找并清理子任务
		local todo_path = todo_link.path
		local todo_bufnr = vim.fn.bufnr(todo_path)
		if todo_bufnr == -1 then
			todo_bufnr = vim.fn.bufadd(todo_path)
			vim.fn.bufload(todo_bufnr)
		end

		local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)
		local todo_line = todo_link.line or 1

		if todo_line <= #lines then
			local parent_line_content = lines[todo_line]
			local parent_indent = parent_line_content:match("^(%s*)") or ""

			-- 收集子任务ID
			local child_ids = {}
			for i = todo_line + 1, #lines do
				local line = lines[i]
				local indent = line:match("^(%s*)") or ""

				-- 如果缩进级别减小或相同，停止搜索
				if #indent <= #parent_indent then
					break
				end

				-- 检查是否是任务行
				if line:match("^%s*[%-%*+]%s+%[[ xX]%]") then
					local child_id = line:match("{#(%w+)}")
					if child_id then
						table.insert(child_ids, child_id)
					end
				end
			end

			-- 批量删除子任务
			for _, child_id in ipairs(child_ids) do
				M.delete_store_links_by_id(child_id)

				-- 同时删除对应的代码标记
				local child_code_link = store_link.get_code(child_id, { verify_line = false })
				if child_code_link and child_code_link.path and child_code_link.line then
					local code_bufnr = vim.fn.bufadd(child_code_link.path)
					vim.fn.bufload(code_bufnr)

					-- 清理渲染缓存
					local renderer = module.get("link.renderer")
					if renderer and renderer.invalidate_render_cache_for_line then
						renderer.invalidate_render_cache_for_line(code_bufnr, child_code_link.line - 1)
					end

					-- 从存储中删除
					store_link.delete_code(child_id)
				end
			end
		end
	end

	-- 先清理渲染，再删除
	local code_link = store_link.get_code(id, { verify_line = false })
	if code_link and code_link.path and code_link.line then
		local bufnr = vim.fn.bufadd(code_link.path)
		vim.fn.bufload(bufnr)

		-- 清理这行的渲染
		local renderer = module.get("link.renderer")
		if renderer and renderer.invalidate_render_cache_for_line then
			renderer.invalidate_render_cache_for_line(bufnr, code_link.line - 1)
		end
	end

	local deleted_code = M.delete_code_link_by_id(id)
	local deleted_store = M.delete_store_links_by_id(id)

	if deleted_code or deleted_store then
		local ui = module.get("ui")
		if ui and ui.show_notification then
			ui.show_notification(string.format("已同步删除标记 %s 的代码与存储记录", id))
		else
			vim.notify(string.format("已同步删除标记 %s 的代码与存储记录", id), vim.log.levels.INFO)
		end
	end
end

---------------------------------------------------------------------
-- 代码被删除 → 同步删除 TODO + store（事件驱动，修复存储API调用）
---------------------------------------------------------------------
function M.on_code_deleted(id, opts)
	opts = opts or {}

	if not id or id == "" then
		return
	end

	-- ⭐ 修复：使用正确的存储模块API
	local store_link = module.get("store.link")

	local link = store_link.get_todo(id, { verify_line = true })

	-- 如果 store 中已经没有 TODO 记录 → 只删 store
	if not link then
		M.delete_store_links_by_id(id)
		return
	end

	local todo_path = link.path
	local bufnr = vim.fn.bufnr(todo_path)

	if bufnr == -1 then
		bufnr = vim.fn.bufadd(todo_path)
		vim.fn.bufload(bufnr)
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local real_line = nil

	for i, line in ipairs(lines) do
		if line:match("{#" .. id .. "}") then
			real_line = i
			break
		end
	end

	if not real_line then
		M.delete_store_links_by_id(id)
		return
	end

	-- 删除 TODO 行
	pcall(function()
		delete_buffer_lines(bufnr, real_line, real_line)
		request_autosave(bufnr)
	end)

	-- ⭐ 关键修复：清理解析树缓存
	local parser = module.get("core.parser")
	if parser and parser.invalidate_cache then
		parser.invalidate_cache(todo_path)
	end

	-- 删除 store
	M.delete_store_links_by_id(id)

	-- 事件驱动刷新
	trigger_state_change("on_code_deleted", bufnr, { id })

	local ui = module.get("ui")
	if ui and ui.show_notification then
		ui.show_notification(string.format("已同步删除标记 %s 的 TODO 与存储记录", id))
	else
		vim.notify(string.format("已同步删除标记 %s 的 TODO 与存储记录", id), vim.log.levels.INFO)
	end
end

---------------------------------------------------------------------
-- 代码侧删除（与 TODO 侧完全对称，事件驱动）
---------------------------------------------------------------------
function M.delete_code_link()
	local bufnr = vim.api.nvim_get_current_buf()

	-- 1. 获取删除范围（支持可视模式）
	local mode = vim.fn.mode()
	local start_lnum, end_lnum

	if mode == "v" or mode == "V" then
		start_lnum = vim.fn.line("v")
		end_lnum = vim.fn.line(".")
		if start_lnum > end_lnum then
			start_lnum, end_lnum = end_lnum, start_lnum
		end
	else
		start_lnum = vim.fn.line(".")
		end_lnum = start_lnum
	end

	local ids = {}
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)

	for _, line in ipairs(lines) do
		for id in line:gmatch("[A-Z][A-Z0-9_]*:ref:(%w+)") do
			table.insert(ids, id)
		end
	end

	-- 先清理这些行的渲染
	local renderer = module.get("link.renderer")
	if renderer and renderer.invalidate_render_cache_for_lines then
		local rows_to_clear = {}
		for i = start_lnum - 1, end_lnum - 1 do
			table.insert(rows_to_clear, i)
		end
		renderer.invalidate_render_cache_for_lines(bufnr, rows_to_clear)
	end

	-- 3. 同步删除（TODO + store）
	for _, id in ipairs(ids) do
		pcall(function()
			M.on_code_deleted(id, { code_already_deleted = true })
		end)
	end

	-- 4. 删除代码行（不模拟 dd，直接删）
	delete_buffer_lines(bufnr, start_lnum, end_lnum)

	-- 5. 自动保存 + 事件驱动刷新
	request_autosave(bufnr)
	trigger_state_change("delete_code_link", bufnr, ids)
end

--- 批量删除TODO链接（代码标记）
--- @param ids string[] 要删除的ID列表
--- @param opts table 选项，包含：todo_bufnr, todo_file
function M.batch_delete_todo_links(ids, opts)
	opts = opts or {}

	if not ids or #ids == 0 then
		return
	end

	-- ⭐ 修复：使用正确的存储模块API
	local store_link = module.get("store.link")

	-- 按照文件分组，批量处理
	local store_index = require("todo2.store.index")
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

	-- 获取渲染器模块用于清理
	local renderer = module.get("link.renderer")

	-- 按文件分组删除代码标记
	for file, links in pairs(code_links_by_file) do
		-- 按行号降序排序，确保删除时行号不会变化
		table.sort(links, function(a, b)
			return a.line > b.line
		end)

		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)

		-- 在删除前清理这些行的渲染
		if renderer and renderer.invalidate_render_cache_for_lines then
			local rows_to_clear = {}
			for _, link in ipairs(links) do
				-- 行号从1开始，转换为0-based索引
				table.insert(rows_to_clear, link.line - 1)
			end
			renderer.invalidate_render_cache_for_lines(bufnr, rows_to_clear)
		end

		-- 批量删除行
		for _, link in ipairs(links) do
			local line_content = vim.api.nvim_buf_get_lines(bufnr, link.line - 1, link.line, false)[1]
			if line_content and line_content:match(link.id) then
				vim.api.nvim_buf_set_lines(bufnr, link.line - 1, link.line, false, {})

				-- 从存储中删除
				store_link.delete_code(link.id)
			end
		end

		-- 确保重新渲染整个缓冲区，清理残留的extmark
		if renderer and renderer.render_code_status then
			-- 使用pcall防止渲染错误
			pcall(renderer.render_code_status, bufnr)
		end

		-- 保存文件并触发事件
		request_autosave(bufnr)
	end

	-- 批量从存储中删除TODO链接记录
	for _, id in ipairs(ids) do
		store_link.delete_todo(id)
	end

	-- 触发状态变更事件
	if opts.todo_bufnr then
		trigger_state_change("batch_delete_todo_links", opts.todo_bufnr, ids)
	end

	-- 显示通知
	local ui = module.get("ui")
	if ui and ui.show_notification then
		ui.show_notification(string.format("已批量删除 %d 个任务的代码标记", #ids))
	end

	return true
end

return M
