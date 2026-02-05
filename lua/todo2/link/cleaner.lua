-- lua/todo2/link/cleaner.lua
--- @module todo2.link.cleaner

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 工具函数：文件是否存在
---------------------------------------------------------------------
local function file_exists(path)
	return vim.fn.filereadable(path) == 1
end

---------------------------------------------------------------------
-- 工具函数：行号是否越界
---------------------------------------------------------------------
local function line_valid(path, line)
	if not file_exists(path) then
		return false
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return false
	end
	return line >= 1 and line <= #lines
end

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
	autosave.request_save(bufnr) -- 只保存，不触发事件
end

local function delete_buffer_lines(bufnr, start_line, end_line)
	local count = end_line - start_line + 1
	vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, {})
	return count
end

---------------------------------------------------------------------
-- ⭐ 自动清理所有无效链接 - 修复版本
---------------------------------------------------------------------
function M.cleanup_all_links()
	local store_mod = module.get("store")
	if not store_mod then
		vim.notify("无法获取 store 模块", vim.log.levels.ERROR)
		return
	end

	-- ⭐ 修复：确保 get_all_*_links 返回表而不是 nil
	local all_code = store_mod.get_all_code_links() or {}
	local all_todo = store_mod.get_all_todo_links() or {}

	-----------------------------------------------------------------
	-- 1. 删除无头 TODO（没有 code link）
	-----------------------------------------------------------------
	for id, todo in pairs(all_todo) do
		if not all_code[id] then
			store_mod.delete_todo_link(id)
		end
	end

	-----------------------------------------------------------------
	-- 2. 删除无头 CODE（没有 todo link）
	-----------------------------------------------------------------
	-- ⭐ 重新获取数据，因为前面的删除可能改变了数据
	all_code = store_mod.get_all_code_links() or {}
	all_todo = store_mod.get_all_todo_links() or {}

	for id, code in pairs(all_code) do
		if not all_todo[id] then
			store_mod.delete_code_link(id)
		end
	end

	-----------------------------------------------------------------
	-- 3. 删除不存在文件的链接
	-----------------------------------------------------------------
	all_code = store_mod.get_all_code_links() or {}
	for id, code in pairs(all_code) do
		if not file_exists(code.path) then
			store_mod.delete_code_link(id)
		end
	end

	all_todo = store_mod.get_all_todo_links() or {}
	for id, todo in pairs(all_todo) do
		if not file_exists(todo.path) then
			store_mod.delete_todo_link(id)
		end
	end

	-----------------------------------------------------------------
	-- 4. 删除越界行号的链接
	-----------------------------------------------------------------
	all_code = store_mod.get_all_code_links() or {}
	for id, code in pairs(all_code) do
		if not line_valid(code.path, code.line) then
			store_mod.delete_code_link(id)
		end
	end

	all_todo = store_mod.get_all_todo_links() or {}
	for id, todo in pairs(all_todo) do
		if not line_valid(todo.path, todo.line) then
			store_mod.delete_todo_link(id)
		end
	end
end

---------------------------------------------------------------------
-- 修复当前 buffer 的孤立标记（多标签版，事件驱动）
---------------------------------------------------------------------
function M.cleanup_orphan_links_in_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local removed = 0
	local affected_ids = {}

	----------------------------------------------------------------
	-- 1. 尝试解析 TODO 任务树，构建 { id -> 子树范围 } 映射
	----------------------------------------------------------------
	local core_ok, core = pcall(module.get, "core")
	local id_ranges = {}
	if core_ok and core.parse_tasks then
		local tasks = core.parse_tasks(lines)

		local function compute_subtree_end(task)
			local max_line = task.line_num or 1
			for _, child in ipairs(task.children or {}) do
				local child_max = compute_subtree_end(child)
				if child_max > max_line then
					max_line = child_max
				end
			end
			return max_line
		end

		for _, task in ipairs(tasks) do
			local line = lines[task.line_num] or ""
			local id = line:match("{#(%w+)}")
			if id then
				local subtree_end = compute_subtree_end(task)
				id_ranges[id] = {
					start = task.line_num,
					["end"] = subtree_end,
				}
			end
		end
	end

	----------------------------------------------------------------
	-- 2. 从底向上扫描行，删除孤立标记
	----------------------------------------------------------------
	local handled_todo_ids = {}

	for i = #lines, 1, -1 do
		local line = lines[i]

		-- 代码 → TODO
		local _, id = line:match("([A-Z][A-Z0-9_]+):ref:(%w+)")
		if id then
			local store = module.get("store")
			local link = store.get_todo_link(id)
			if not link then
				removed = removed + delete_buffer_lines(bufnr, i, i)
				local deleter = module.get("link.deleter")
				if deleter and deleter.delete_store_links_by_id then
					deleter.delete_store_links_by_id(id)
				end
				table.insert(affected_ids, id)
			end
		end

		-- TODO → 代码
		local id2 = line:match("{#(%w+)}")
		if id2 then
			local store = module.get("store")
			local link = store.get_code_link(id2)
			if not link then
				local range = id_ranges[id2]
				if range and not handled_todo_ids[id2] then
					local start_idx = math.max(1, math.min(range.start, #lines))
					local end_idx = math.max(start_idx, math.min(range["end"], #lines))

					removed = removed + delete_buffer_lines(bufnr, start_idx, end_idx)
					handled_todo_ids[id2] = true
					local deleter = module.get("link.deleter")
					if deleter and deleter.delete_store_links_by_id then
						deleter.delete_store_links_by_id(id2)
					end
					table.insert(affected_ids, id2)
				else
					removed = removed + delete_buffer_lines(bufnr, i, i)
					local deleter = module.get("link.deleter")
					if deleter and deleter.delete_store_links_by_id then
						deleter.delete_store_links_by_id(id2)
					end
					table.insert(affected_ids, id2)
				end
			end
		end
	end

	-- 通过UI模块显示通知
	local ui = module.get("ui")
	if ui and ui.show_notification then
		ui.show_notification(string.format("已清理 %d 个孤立标记（含子任务）", removed))
	else
		vim.notify(string.format("已清理 %d 个孤立标记（含子任务）", removed), vim.log.levels.INFO)
	end

	-- 自动保存 + 事件驱动刷新
	request_autosave(bufnr)
	trigger_state_change("cleanup_orphan_links_in_buffer", bufnr, affected_ids)
end

return M
