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
	events.on_state_changed({
		source = source,
		file = vim.api.nvim_buf_get_name(bufnr),
		bufnr = bufnr,
		ids = ids,
	})
end

local function request_autosave(bufnr)
	local autosave = module.get("core.autosave")
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

return M
