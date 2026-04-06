-- lua/todo2/render/scheduler.lua
-- 简化版：移除 TTL 缓存，使用 changedtick 检测变化
-- 保持所有外部接口不变

local M = {}

local rendering = {}
local pending = {}
local DEBOUNCE = 10

-- 简化缓存：只保存 changedtick 和解析结果
local parse_cache = {} -- bufnr -> { tick, tasks, roots, id_to_task, archive_trees }
-- 移除 file_lines_cache

local uv = vim.loop
local file = require("todo2.utils.file")
local conceal = require("todo2.render.conceal")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

local function now_ms()
	return uv.now()
end

local function get_absolute_path(path)
	return file.normalize_path(path)
end

local function get_bufnr_from_path(path)
	if not path or path == "" then
		return nil
	end
	local abs = get_absolute_path(path)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			local buf_path = vim.api.nvim_buf_get_name(bufnr)
			if buf_path and get_absolute_path(buf_path) == abs then
				return bufnr
			end
		end
	end
	return nil
end

---------------------------------------------------------------------
-- 文件行获取（移除缓存，直接读取）
---------------------------------------------------------------------

---获取文件行（不再缓存）
---@param path string
---@param force_refresh boolean (保留参数以保持接口兼容，但不再使用)
---@return string[]
function M.get_file_lines(path, force_refresh)
	if not path or path == "" then
		return {}
	end
	local abs = get_absolute_path(path)
	if abs == "" then
		return {}
	end
	return file.read_lines(abs)
end

function M.invalidate_file_cache(path)
	-- 移除了文件缓存，这个函数现在什么都不做
	-- 保留以保持接口兼容
end

---------------------------------------------------------------------
-- 解析缓存（基于 changedtick）
---------------------------------------------------------------------

---获取解析树
---@param path string
---@param force_refresh boolean
---@return table[], table[], table<string, table>, table<string, table>
function M.get_parse_tree(path, force_refresh)
	if not path or path == "" then
		return {}, {}, {}, {}
	end

	local bufnr = get_bufnr_from_path(path)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		-- 缓冲区不存在，直接解析但不缓存
		local lines = M.get_file_lines(path, force_refresh)
		local parser = require("todo2.core.parser")
		return parser.parse_lines(path, lines)
	end

	local current_tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = parse_cache[bufnr]

	-- 如果文件没变化且不强制刷新，使用缓存
	if not force_refresh and cached and cached.tick == current_tick then
		return cached.tasks, cached.roots, cached.id_to_task, cached.archive_trees
	end

	-- 重新解析
	local lines = M.get_file_lines(path, force_refresh)
	local parser = require("todo2.core.parser")
	local tasks, roots, id_to_task, archive_trees = parser.parse_lines(path, lines)

	-- 缓存结果
	parse_cache[bufnr] = {
		tick = current_tick,
		tasks = tasks,
		roots = roots,
		id_to_task = id_to_task,
		archive_trees = archive_trees,
		time = now_ms(), -- 保留 time 字段以防其他地方使用，但不再用于 TTL
	}

	return tasks, roots, id_to_task, archive_trees
end

function M.invalidate_cache(path)
	if path and path ~= "" then
		local bufnr = get_bufnr_from_path(path)
		if bufnr then
			parse_cache[bufnr] = nil
		end
		M.invalidate_file_cache(path)
	else
		parse_cache = {}
		-- file_lines_cache 已移除
	end
end

---------------------------------------------------------------------
-- 对外接口：解析
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
---@param opts? {
---   force_refresh?: boolean,
---   changed_ids?: string[],
---   deleted_locations?: table[]
--- }
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
		-- TODO 文件：全量渲染
		local todo_render = require("todo2.render.todo_render")
		-- 强制刷新缓存
		M.invalidate_cache(path)
		count = todo_render.render(bufnr)
	else
		-- 代码文件：增量渲染
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

---编辑后刷新
---@param bufnr number
---@param opts? table
---@return number
function M.refresh_after_edit(bufnr, opts)
	opts = opts or {}
	opts.force_refresh = true
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

---清理所有缓存
function M.clear()
	rendering = {}
	pending = {}
	parse_cache = {}
	-- file_lines_cache 已移除
end

return M
