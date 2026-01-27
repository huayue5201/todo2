-- lua/todo2/manager.lua
--- @module todo2.manager
--- @brief 负责双链管理：孤立修复、删除同步、统计、store 管理（展示层已移除）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------
-- 触发状态变更事件
local function trigger_state_change(source, bufnr, ids)
	if #ids == 0 then
		return
	end

	local events = module.get("core.events")
	events.on_state_changed({
		source = source,
		file = vim.api.nvim_buf_get_name(bufnr),
		bufnr = bufnr,
		ids = ids,
	})
end

-- 请求自动保存
local function request_autosave(bufnr)
	local autosave = module.get("core.autosave")
	autosave.request_save(bufnr)
end

-- 删除buffer行并返回删除的行数
local function delete_buffer_lines(bufnr, start_line, end_line)
	local count = end_line - start_line + 1
	vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, {})
	return count
end

---------------------------------------------------------------------
-- 修复：删除当前 buffer 的孤立标记（多标签版，事件驱动）
---------------------------------------------------------------------
function M.fix_orphan_links_in_buffer()
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
				M.delete_store_links_by_id(id)
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
					M.delete_store_links_by_id(id2)
					table.insert(affected_ids, id2)
				else
					removed = removed + delete_buffer_lines(bufnr, i, i)
					M.delete_store_links_by_id(id2)
					table.insert(affected_ids, id2)
				end
			end
		end
	end

	vim.notify(string.format("已清理 %d 个孤立标记（含子任务）", removed), vim.log.levels.INFO)

	-- 自动保存 + 事件驱动刷新
	request_autosave(bufnr)
	trigger_state_change("fix_orphan_links_in_buffer", bufnr, affected_ids)
end

---------------------------------------------------------------------
-- 双链删除（完全对称 + 安全顺序）
---------------------------------------------------------------------

--- 删除代码文件中的标记行
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

--- 删除 store 中的记录
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

--- TODO 被删除 → 同步删除代码 + store
function M.on_todo_deleted(id)
	if not id or id == "" then
		return
	end

	local deleted_code = M.delete_code_link_by_id(id)
	local deleted_store = M.delete_store_links_by_id(id)

	if deleted_code or deleted_store then
		vim.notify(string.format("已同步删除标记 %s 的代码与存储记录", id), vim.log.levels.INFO)
	end
end

--- 代码被删除 → 同步删除 TODO + store（事件驱动）
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

	vim.notify(string.format("已同步删除标记 %s 的 TODO 与存储记录", id), vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- 代码侧删除（与 TODO 侧完全对称，事件驱动）
---------------------------------------------------------------------
-- TODO:ref:408605
-- TODO:ref:3ed4a8
function M.delete_code_link()
	local bufnr = vim.api.nvim_get_current_buf()

	----------------------------------------------------------------
	-- 1. 获取删除范围（支持可视模式）
	----------------------------------------------------------------
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

	----------------------------------------------------------------
	-- 2. 收集 TAG:ref:id
	----------------------------------------------------------------
	local ids = {}
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)

	for _, line in ipairs(lines) do
		for id in line:gmatch("[A-Z][A-Z0-9_]*:ref:(%w+)") do
			table.insert(ids, id)
		end
	end

	----------------------------------------------------------------
	-- 3. 同步删除（TODO + store）
	----------------------------------------------------------------
	for _, id in ipairs(ids) do
		pcall(function()
			M.on_code_deleted(id, { code_already_deleted = true })
		end)
	end

	----------------------------------------------------------------
	-- 4. 删除代码行（不模拟 dd，直接删）
	----------------------------------------------------------------
	delete_buffer_lines(bufnr, start_lnum, end_lnum)

	----------------------------------------------------------------
	-- 5. 自动保存 + 事件驱动刷新
	----------------------------------------------------------------
	request_autosave(bufnr)
	trigger_state_change("delete_code_link", bufnr, ids)
end

---------------------------------------------------------------------
-- 工具：重新加载 store
---------------------------------------------------------------------
function M.reload_store()
	module.reload("store")
	vim.notify("store 模块已重新加载", vim.log.levels.INFO)
end

return M
