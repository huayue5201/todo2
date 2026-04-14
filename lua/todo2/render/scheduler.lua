-- lua/todo2/render/scheduler.lua
-- 简化版：移除所有缓存，只负责调度渲染

local M = {}

local rendering = {}
local pending = {}
local DEBOUNCE = 10

local file = require("todo2.utils.file")
local conceal = require("todo2.render.conceal")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

local function get_bufnr_from_path(path)
	if not path or path == "" then
		return nil
	end
	local abs = file.normalize_path(path)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			local buf_path = vim.api.nvim_buf_get_name(bufnr)
			if buf_path and file.normalize_path(buf_path) == abs then
				return bufnr
			end
		end
	end
	return nil
end

---------------------------------------------------------------------
-- 解析接口（无缓存，直接从 buffer 读取）
---------------------------------------------------------------------

---获取解析树（直接从 buffer 解析，无缓存）
---@param path string
---@return table[], table[], table<string, table>, table<string, table>
function M.get_parse_tree(path)
	if not path or path == "" then
		return {}, {}, {}, {}
	end

	local bufnr = get_bufnr_from_path(path)
	local lines = {}

	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	else
		lines = file.read_lines(path)
	end

	local parser = require("todo2.core.parser")
	return parser.parse_lines(path, lines)
end

---获取缓冲区的解析树
---@param bufnr number
---@param opts? { force_refresh?: boolean }
---@return table[], table[], table<string, table>, table<string, table>
function M.get_tasks_for_buf(bufnr, opts)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return {}, {}, {}, {}
	end
	local path = file.buf_path(bufnr)
	if path == "" then
		return {}, {}, {}, {}
	end
	return M.get_parse_tree(path)
end

---------------------------------------------------------------------
-- 缓存清理（保留空函数以兼容旧代码）
---------------------------------------------------------------------

function M.invalidate_cache(path)
	-- 已移除缓存，此函数保留仅为兼容性
end

function M.clear()
	rendering = {}
	pending = {}
end

---------------------------------------------------------------------
-- 渲染调度
---------------------------------------------------------------------

local function finish(bufnr, count)
	rendering[bufnr] = nil

	local next_opts = pending[bufnr]
	if next_opts then
		pending[bufnr] = nil
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				M.refresh(bufnr, next_opts)
			end
		end, DEBOUNCE)
	end

	return count or 0
end

---刷新缓冲区渲染
---@param bufnr number
---@param opts? { changed_ids?: string[], deleted_locations?: table[] }
---@return number
function M.refresh(bufnr, opts)
	opts = opts or {}

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	if rendering[bufnr] then
		pending[bufnr] = opts
		return 0
	end

	rendering[bufnr] = true

	local path = file.buf_path(bufnr)
	if path == "" then
		return finish(bufnr, 0)
	end

	local is_todo = file.is_todo_file(path)
	local count = 0

	if is_todo then
		local todo_render = require("todo2.render.todo_render")
		if opts.changed_ids and #opts.changed_ids > 0 then
			count = todo_render.render_changed(bufnr, opts.changed_ids)
		else
			count = todo_render.render(bufnr)
		end
	else
		local code_render = require("todo2.render.code_render")
		if opts.changed_ids and #opts.changed_ids > 0 then
			count = code_render.render_changed(bufnr, opts.changed_ids, opts.deleted_locations)
		else
			count = code_render.render_file(bufnr)
		end
	end

	-- 刷新 conceal
	conceal.apply_buffer_conceal(bufnr)

	return finish(bufnr, count)
end

---编辑后刷新（保留兼容）
---@param bufnr number
---@param opts? table
---@return number
function M.refresh_after_edit(bufnr, opts)
	return M.refresh(bufnr, opts)
end

---按文件路径刷新
---@param paths string[]
---@param opts? { changed_ids?: string[], deleted_locations?: table[] }
function M.refresh_files(paths, opts)
	if not paths or #paths == 0 then
		return
	end
	for _, p in ipairs(paths) do
		local bufnr = vim.fn.bufnr(p)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			M.refresh(bufnr, opts)
		end
	end
end

---刷新所有已加载缓冲区
---@param opts? { changed_ids?: string[], deleted_locations?: table[] }
function M.refresh_all(opts)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			M.refresh(b, opts)
		end
	end
end

return M
