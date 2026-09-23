-- lua/todo2/task/cursor.lua
-- 光标处任务查询：统一 TODO 文件与代码文件的“当前任务”查找逻辑

local M = {}

local file = require("todo2.utils.file")
local id_utils = require("todo2.utils.id")
local index = require("todo2.store.index")
local core = require("todo2.store.task.core")

---获取代码文件中指定行的任务（轻量索引任务）
---@param bufnr number|nil 缓冲区号，nil 表示当前缓冲区
---@param lnum number|nil 行号，nil 表示当前行
---@return table|nil
function M.get_code_task(bufnr, lnum)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	lnum = lnum or vim.fn.line(".")
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return nil
	end
	return index.find_code_task_at_line(path, lnum)
end

---获取光标处任务 ID（兼容 TODO 文件和代码文件）
---@param bufnr number|nil 缓冲区号，nil 表示当前缓冲区
---@param lnum number|nil 行号，nil 表示当前行
---@return string|nil
function M.get_id(bufnr, lnum)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	lnum = lnum or vim.fn.line(".")
	local filename = vim.api.nvim_buf_get_name(bufnr)

	if file.is_todo_file(filename) then
		local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
		return id_utils.extract_id_from_line(line)
	end

	local task = M.get_code_task(bufnr, lnum)
	return task and task.id or nil
end

---获取光标处完整任务对象
---@param bufnr number|nil 缓冲区号，nil 表示当前缓冲区
---@param lnum number|nil 行号，nil 表示当前行
---@return table|nil
function M.get_task(bufnr, lnum)
	local id = M.get_id(bufnr, lnum)
	if not id then
		return nil
	end
	return core.get_task(id)
end

return M
