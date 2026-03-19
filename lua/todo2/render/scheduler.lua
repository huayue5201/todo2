-- lua/todo2/render/scheduler.lua
-- 渲染调度器：只负责缓存和调度，不合并数据

local M = {}

local rendering = {}
local pending = {}
local DEBOUNCE = 10

local parse_cache = {} -- abs_path -> { tasks, roots, id_to_task, archive_trees, time, mtime }
local file_lines_cache = {} -- abs_path -> { lines, time }
local PARSE_CACHE_TTL = 5000
local FILE_CACHE_TTL = 1000

local parser = nil
local uv = vim.loop
local file = require("todo2.utils.file")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

local function now_ms()
	return uv.now()
end

local function get_absolute_path(path)
	return file.normalize_path(path)
end

---------------------------------------------------------------------
-- 文件行缓存
---------------------------------------------------------------------

---获取文件行（带缓存）
---@param path string
---@param force_refresh boolean
---@return string[]
function M.get_file_lines(path, force_refresh)
	local abs = get_absolute_path(path)
	if abs == "" then
		return {}
	end

	local entry = file_lines_cache[abs]
	local ts = now_ms()

	if not force_refresh and entry and (ts - entry.time) < FILE_CACHE_TTL then
		return entry.lines
	end

	local lines = file.read_lines(abs)
	file_lines_cache[abs] = { lines = lines, time = ts }
	return lines
end

function M.invalidate_file_cache(path)
	if not path or path == "" then
		file_lines_cache = {}
		return
	end
	local abs = get_absolute_path(path)
	file_lines_cache[abs] = nil
end

---------------------------------------------------------------------
-- 解析缓存
---------------------------------------------------------------------

local function ensure_parser()
	if not parser then
		parser = require("todo2.core.parser")
	end
end

---获取解析树（只返回解析器的原始结构）
---@param path string
---@param force_refresh boolean
---@return table[], table[], table<string, table>, table<string, table>
function M.get_parse_tree(path, force_refresh)
	if not path or path == "" then
		return {}, {}, {}, {}
	end

	ensure_parser()
	local abs = get_absolute_path(path)
	local ts = now_ms()

	local cached = parse_cache[abs]
	if not force_refresh and cached and (ts - (cached.time or 0)) < PARSE_CACHE_TTL then
		return cached.tasks, cached.roots, cached.id_to_task, cached.archive_trees
	end

	local lines = M.get_file_lines(abs, force_refresh)
	local tasks, roots, id_to_task, archive_trees = parser.parse_lines(abs, lines)

	local stat = uv.fs_stat(abs)
	local mtime = stat and stat.mtime and stat.mtime.sec or 0

	parse_cache[abs] = {
		tasks = tasks,
		roots = roots,
		id_to_task = id_to_task,
		archive_trees = archive_trees,
		time = ts,
		mtime = mtime,
	}

	return tasks, roots, id_to_task, archive_trees
end

function M.invalidate_cache(path)
	if path and path ~= "" then
		local abs = get_absolute_path(path)
		parse_cache[abs] = nil
		M.invalidate_file_cache(abs)
	else
		parse_cache = {}
		file_lines_cache = {}
	end
end

---------------------------------------------------------------------
-- 对外接口
---------------------------------------------------------------------

---获取缓冲区的解析树
---@param bufnr number
---@param opts? { force_refresh?: boolean }
---@return table[], table[], table<string, table>, table<string, table>
function M.get_tasks_for_buf(bufnr, opts)
	opts = opts or {}
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return {}, {}, {}, {}
	end
	local path = file.buf_path(bufnr)
	if path == "" then
		return {}, {}, {}, {}
	end
	return M.get_parse_tree(path, opts.force_refresh)
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
---@param opts? { force_refresh?: boolean, changed_ids?: string[] }
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

	-- 如果有 force_refresh，先清理缓存
	if opts.force_refresh then
		M.invalidate_cache(path)
	end

	if is_todo then
		local todo_render = require("todo2.render.todo_render")
		local count
		if opts.changed_ids and #opts.changed_ids > 0 then
			count = todo_render.render_changed(bufnr, opts.changed_ids)
		else
			count = todo_render.render(bufnr)
		end
		return finish(bufnr, count)
	else
		local code_render = require("todo2.render.code_render")
		local count
		if opts.changed_ids and #opts.changed_ids > 0 then
			count = code_render.render_changed(bufnr, opts.changed_ids)
		else
			count = code_render.render_file(bufnr)
		end
		return finish(bufnr, count)
	end
end

---编辑后刷新
---@param bufnr number
---@param opts? table
---@return number
function M.refresh_after_edit(bufnr, opts)
	opts = opts or {}
	opts.force_refresh = true
	return M.refresh(bufnr, opts)
end

---刷新所有缓冲区
---@param opts? table
function M.refresh_all(opts)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			M.refresh(b, opts)
		end
	end
end

---清理所有缓存
function M.clear()
	rendering = {}
	pending = {}
	parse_cache = {}
	file_lines_cache = {}
end

return M
