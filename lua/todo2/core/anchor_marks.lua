-- lua/todo2/core/anchor_marks.lua
-- 代码锚点的「列」跟踪：用不可见 extmark 让 Neovim 在编辑中维护 col/end_col。
--
-- 设计要点：
--   * extmark 只负责位置跟踪，不参与锚点身份判定（身份仍看 line_text）；
--   * 渲染时按行重建 mark；编辑后从 mark 回读最新列并写回内存；
--   * 持久化做防抖，避免每次按键都写盘。

local M = {}

local constants = require("todo2.constants")
local core = require("todo2.store.task.core")
local anchor_utils = require("todo2.utils.anchor")

local NS = constants.ns("code_col")

---@type table<number, table<string, integer>> bufnr -> task_id -> extmark id
local marks = {}
---@type table<number, string> bufnr -> path
local paths = {}
---@type table<number, integer> bufnr -> generation（用于取消过期防抖）
local generations = {}

local FLUSH_DELAY = 600

--- 为某一行重建列跟踪 extmark。
---@param bufnr number
---@param row number 0-based
---@param tasks table[]
function M.set_row(bufnr, row, tasks)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

	local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local per_buf = marks[bufnr]
	if not per_buf then
		per_buf = {}
		marks[bufnr] = per_buf
	end

	for _, task in ipairs(tasks or {}) do
		local loc = task.locations and task.locations.code
		if loc and type(loc.col) == "number" then
			if not core.is_anchor_lost(task) then
				local col = anchor_utils.clamp(text, loc.col)
				local end_col = anchor_utils.clamp(text, loc.end_col or (col + 1))
				if end_col <= col and col < #text then
					end_col = col + 1
				end
				if col < end_col then
					local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, col, {
						end_col = end_col,
						right_gravity = true,
						end_right_gravity = false,
						priority = 10,
					})
					if ok then
						per_buf[task.id] = mark_id
					end
				end
			end
		end
	end
end

--- 清除某一行（或整个 buffer）的列跟踪 mark。
---@param bufnr number
---@param row? number 0-based；省略则清空整个 buffer
function M.clear(bufnr, row)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if row ~= nil then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)
	else
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
		marks[bufnr] = nil
	end
end

--- 从当前 buffer 的 extmark 回读最新列，写回任务对象。
---@param bufnr number
---@param path string
---@return { id: string, task: table }[] changed
function M.update_memory(bufnr, path)
	local per_buf = marks[bufnr]
	if not per_buf or not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end

	local changed = {}
	local lines
	for id, mark_id in pairs(per_buf) do
		local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, mark_id, { details = true })
		if pos and pos[1] ~= nil then
			local task = core.get_task(id)
			local loc = task and task.locations and task.locations.code
			if loc and loc.path == path then
				local row = pos[1] + 1
				if row == loc.line then
					lines = lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
					local text = lines[row] or ""
					local col = anchor_utils.clamp(text, pos[2])
					local end_col = anchor_utils.clamp(text, (pos[3] and pos[3].end_col) or col)
					if end_col < col then
						end_col = col
					end
					if loc.col ~= col or loc.end_col ~= end_col then
						loc.col = col
						loc.end_col = end_col
						changed[#changed + 1] = { id = id, task = task }
					end
				end
			end
		end
	end
	return changed
end

--- 立即把当前列持久化到 store（会更新 updated 时间戳）。
---@param bufnr number
---@param path string
---@return integer saved
function M.flush(bufnr, path)
	local changed = M.update_memory(bufnr, path)
	for _, entry in ipairs(changed) do
		core.save_task(entry.id, entry.task)
	end
	return #changed
end

--- 防抖持久化列变化。编辑过程中只更新内存，停顿后再写盘。
---@param bufnr number
---@param path string
function M.schedule_flush(bufnr, path)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	paths[bufnr] = path
	local gen = (generations[bufnr] or 0) + 1
	generations[bufnr] = gen
	vim.defer_fn(function()
		if generations[bufnr] ~= gen then
			return
		end
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		M.flush(bufnr, paths[bufnr] or path)
	end, FLUSH_DELAY)
end

--- buffer 卸载时清理状态。
---@param bufnr number
function M.detach(bufnr)
	marks[bufnr] = nil
	paths[bufnr] = nil
	generations[bufnr] = nil
end

return M
