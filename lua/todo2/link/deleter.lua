-- lua/todo2/link/deleter.lua
--- @module todo2.link.deleter
--- @brief 双链删除管理模块

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 辅助函数
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

-- 修改 request_autosave 函数：
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
-- 删除代码文件中的标记行
---------------------------------------------------------------------
function M.delete_code_link_by_id(id)
	if not id or id == "" then
		return false
	end

	local store = module.get("store")
	local link = store.get_code_link(id)
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
-- 删除 store 中的记录
---------------------------------------------------------------------
function M.delete_store_links_by_id(id)
	if not id or id == "" then
		return false
	end

	local store = module.get("store")

	local had_todo = store.get_todo_link(id) ~= nil
	local had_code = store.get_code_link(id) ~= nil

	if had_todo then
		store.delete_todo_link(id)
	end
	if had_code then
		store.delete_code_link(id)
	end

	return had_todo or had_code
end

---------------------------------------------------------------------
-- TODO 被删除 → 同步删除代码 + store
---------------------------------------------------------------------
function M.on_todo_deleted(id)
	if not id or id == "" then
		return
	end

	-- ⭐ 修改：先清理渲染，再删除
	local store = module.get("store")
	local code_link = store.get_code_link(id)
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
-- 代码被删除 → 同步删除 TODO + store（事件驱动）
---------------------------------------------------------------------
function M.on_code_deleted(id, opts)
	opts = opts or {}

	if not id or id == "" then
		return
	end

	local store = module.get("store")
	local link = store.get_todo_link(id, { force_relocate = true })

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

	-- 2. 收集 TAG:ref:id
	local ids = {}
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)

	for _, line in ipairs(lines) do
		for id in line:gmatch("[A-Z][A-Z0-9_]*:ref:(%w+)") do
			table.insert(ids, id)
		end
	end

	-- ⭐ 修改：先清理这些行的渲染
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

	-- 按照文件分组，批量处理
	local store = module.get("store")
	local code_links_by_file = {}

	-- 收集每个ID对应的代码链接
	for _, id in ipairs(ids) do
		local code_link = store.get_code_link(id)
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

		-- ⭐ 修改：在删除前清理这些行的渲染
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
				store.delete_code_link(link.id)
			end
		end

		-- ⭐ 确保重新渲染整个缓冲区，清理残留的extmark
		if renderer and renderer.render_code_status then
			-- 使用pcall防止渲染错误
			pcall(renderer.render_code_status, bufnr)
		end

		-- 保存文件并触发事件
		request_autosave(bufnr)
	end

	-- 批量从存储中删除TODO链接记录
	for _, id in ipairs(ids) do
		store.delete_todo_link(id)
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
