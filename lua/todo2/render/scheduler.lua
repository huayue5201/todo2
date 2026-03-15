-- lua/todo2/render/scheduler.lua
-- 优化版：精简字段合并，统一命名

local core = require("todo2.store.link.core")

local M = {}

local rendering = {}
local pending = {}
local DEBOUNCE = 10

local parse_cache = {} -- map abs_path -> { tasks, roots, id_to_task, archive_trees, time, mtime }
local file_lines_cache = {} -- map abs_path -> { lines = {...}, time = ts }
local PARSE_CACHE_TTL = 5000 -- ms
local FILE_CACHE_TTL = 1000 -- ms

local parser = nil
local uv = vim.loop

local function now_ms()
	return uv.now()
end

local function get_absolute_path(path)
	if not path or path == "" then
		return ""
	end
	path = path:gsub("^~", uv.os_homedir())
	local p = vim.fn.fnamemodify(path, ":p")
	local real = uv.fs_realpath(p)
	return real or p
end

---------------------------------------------------------------------
-- 文件行缓存接口
---------------------------------------------------------------------
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

	local ok, lines = pcall(vim.fn.readfile, abs)
	lines = ok and lines or {}
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
-- 解析缓存接口
---------------------------------------------------------------------
local function ensure_parser()
	if not parser then
		parser = require("todo2.core.parser")
	end
end

local function make_parse_cache_key(path)
	return get_absolute_path(path)
end

function M.get_parse_tree(path, force_refresh)
	if not path or path == "" then
		return {}, {}, {}, {}
	end

	ensure_parser()
	local abs = make_parse_cache_key(path)
	local ts = now_ms()

	local cached = parse_cache[abs]
	if not force_refresh and cached and (ts - (cached.time or 0)) < PARSE_CACHE_TTL then
		return cached.tasks or {}, cached.roots or {}, cached.id_to_task or {}, cached.archive_trees or {}
	end

	local lines = M.get_file_lines(abs, force_refresh)
	local raw_tasks, roots, raw_id_to_task, archive_trees

	if parser.parse_lines then
		raw_tasks, roots, raw_id_to_task, archive_trees = parser.parse_lines(abs, lines)
	else
		raw_tasks, roots, raw_id_to_task, archive_trees = parser.parse_file(abs, force_refresh)
	end

	-- 使用新接口获取任务数据
	local merged_tasks = {}
	local merged_id_to_task = {}

	-- 收集所有 ID
	local ids = {}
	for _, task in ipairs(raw_tasks or {}) do
		if task.id then
			ids[task.id] = true
		end
	end

	-- 批量获取任务（内部格式）
	local tasks_map = {}
	for id in pairs(ids) do
		tasks_map[id] = core.get_task(id)
	end

	-- 合并信息到 task 对象
	for _, task in ipairs(raw_tasks or {}) do
		local merged = vim.deepcopy(task)
		if task.id and tasks_map[task.id] then
			local t = tasks_map[task.id]

			-- ⭐ 用存储的状态覆盖文件解析的状态
			merged.status = t.core.status

			-- ⭐ 简化：只附加一个 store 字段，包含所有存储数据
			merged.store = {
				id = t.id,
				status = t.core.status,
				tags = t.core.tags,
				ai_executable = t.core.ai_executable,
				created_at = t.timestamps.created,
				updated_at = t.timestamps.updated,
				completed_at = t.timestamps.completed,
				archived_at = t.timestamps.archived,
				archived_reason = t.timestamps.archived_reason,
				context = t.locations.code and t.locations.code.context,
				code_path = t.locations.code and t.locations.code.path,
				code_line = t.locations.code and t.locations.code.line,
				todo_path = t.locations.todo and t.locations.todo.path,
				todo_line = t.locations.todo and t.locations.todo.line,
			}
		end
		table.insert(merged_tasks, merged)
		if merged.id then
			merged_id_to_task[merged.id] = merged
		end
	end

	local stat = uv.fs_stat(abs)
	local mtime = stat and stat.mtime and stat.mtime.sec or 0

	parse_cache[abs] = {
		tasks = merged_tasks,
		roots = roots or {},
		id_to_task = merged_id_to_task,
		archive_trees = archive_trees or {},
		time = ts,
		mtime = mtime,
	}

	return parse_cache[abs].tasks, parse_cache[abs].roots, parse_cache[abs].id_to_task, parse_cache[abs].archive_trees
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
-- 对外：按 bufnr 获取解析树
---------------------------------------------------------------------
function M.get_tasks_for_buf(bufnr, opts)
	opts = opts or {}
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return {}, {}, {}, {}
	end
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return {}, {}, {}, {}
	end
	return M.get_parse_tree(path, opts.force_refresh)
end

---------------------------------------------------------------------
-- diff（按任务 ID）- 增强版，考虑存储状态
---------------------------------------------------------------------
local function task_changed(a, b, store_map)
	if not a or not b then
		return true
	end
	if a.line_num ~= b.line_num then
		return true
	end
	local ar = a.region and a.region.id or nil
	local br = b.region and b.region.id or nil
	if ar ~= br then
		return true
	end
	-- ⭐ 检查文件状态是否变化
	if a.status ~= b.status then
		return true
	end
	-- ⭐ 检查存储状态是否与文件状态不一致（需要重新渲染）
	if store_map and store_map[a.id] then
		local store_status = store_map[a.id].core.status
		if a.status ~= store_status then
			return true
		end
	end
	return false
end

local function diff_parse_tree(old, new, store_map)
	local changed = {}

	for id, new_task in pairs(new) do
		local old_task = old[id]
		if not old_task or task_changed(old_task, new_task, store_map) then
			changed[id] = true
		end
	end

	for id, _ in pairs(old) do
		if not new[id] then
			changed[id] = true
		end
	end

	return changed
end

---------------------------------------------------------------------
-- 渲染结束统一收尾
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

---------------------------------------------------------------------
-- 核心刷新
---------------------------------------------------------------------
function M.refresh(bufnr, opts)
	opts = opts or {}

	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	if rendering[bufnr] then
		pending[bufnr] = opts
		return 0
	end

	rendering[bufnr] = true

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return finish(bufnr, 0)
	end

	local is_todo = path:match("%.todo%.md$")

	-----------------------------------------------------------------
	-- 获取旧解析树
	-----------------------------------------------------------------
	local abs = get_absolute_path(path)
	local old = {}
	if parse_cache[abs] and parse_cache[abs].id_to_task then
		old = parse_cache[abs].id_to_task
	end

	-----------------------------------------------------------------
	-- from_event：重新解析
	-----------------------------------------------------------------
	if opts.from_event then
		M.invalidate_cache(path)
	end

	-----------------------------------------------------------------
	-- 获取新解析树
	-----------------------------------------------------------------
	local tasks, roots, id_to_task, archive_trees = M.get_parse_tree(path, opts.force_refresh)

	-- 获取存储状态用于 diff
	local store_map = {}
	for id, _ in pairs(id_to_task) do
		store_map[id] = core.get_task(id)
	end

	-----------------------------------------------------------------
	-- TODO 文件：按任务 ID 增量渲染
	-----------------------------------------------------------------
	if is_todo then
		local todo_render = require("todo2.render.todo_render")
		local conceal = require("todo2.render.conceal")

		if opts.force_refresh or vim.tbl_isempty(old) then
			local count = todo_render.render(bufnr, { force_refresh = true })
			if conceal and conceal.apply_smart_conceal then
				pcall(conceal.apply_smart_conceal, bufnr)
			end
			return finish(bufnr, count)
		end

		local changed = diff_parse_tree(old, id_to_task, store_map)
		local count = 0
		local changed_lines = {}

		for id, _ in pairs(changed) do
			local task = id_to_task[id]
			if task and task.line_num then
				pcall(todo_render.render_task, bufnr, task)
				table.insert(changed_lines, task.line_num)
				count = count + 1
			end
		end

		if #changed_lines > 0 then
			local unique = {}
			for _, lnum in ipairs(changed_lines) do
				unique[lnum] = true
			end
			changed_lines = vim.tbl_keys(unique)
			table.sort(changed_lines)

			if conceal and conceal.apply_smart_conceal then
				pcall(conceal.apply_smart_conceal, bufnr, changed_lines)
			end
		else
			if conceal and conceal.apply_smart_conceal then
				pcall(conceal.apply_smart_conceal, bufnr)
			end
		end

		return finish(bufnr, count)
	end

	-----------------------------------------------------------------
	-- CODE 文件：按任务 ID 增量渲染
	-----------------------------------------------------------------
	local code_render = require("todo2.render.code_render")
	local conceal = require("todo2.render.conceal")

	-- ⭐ 支持 changed_id（单数）和 changed_ids（复数）
	local changed_id = opts.changed_id
	if not changed_id and opts.changed_ids and #opts.changed_ids > 0 then
		changed_id = opts.changed_ids[1]
	end

	-- 显式全量
	if opts.force_refresh then
		pcall(code_render.render_code_status, bufnr)
		if conceal and conceal.apply_smart_conceal then
			pcall(conceal.apply_smart_conceal, bufnr)
		end
		return finish(bufnr, 0)
	end

	-- ⭐ 增量渲染
	if changed_id then
		pcall(code_render.render_task_id, changed_id)

		local task = core.get_task(changed_id)
		if task and task.locations.code and task.locations.code.line and conceal and conceal.apply_smart_conceal then
			pcall(conceal.apply_smart_conceal, bufnr, { task.locations.code.line })
		end

		return finish(bufnr, 1)
	end

	-- 否则全量
	pcall(code_render.render_code_status, bufnr)
	if conceal and conceal.apply_smart_conceal then
		pcall(conceal.apply_smart_conceal, bufnr)
	end
	return finish(bufnr, 0)
end

---------------------------------------------------------------------
-- 针对“编辑后”的刷新入口
---------------------------------------------------------------------
function M.refresh_after_edit(bufnr, opts)
	opts = opts or {}
	opts.from_event = true
	opts.force_refresh = true
	return M.refresh(bufnr, opts)
end

---------------------------------------------------------------------
-- refresh_all / clear / stats
---------------------------------------------------------------------
function M.refresh_all(opts)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			M.refresh(b, opts)
		end
	end
end

function M.clear()
	rendering = {}
	pending = {}
	parse_cache = {}
	file_lines_cache = {}
end

function M.get_cache_stats()
	local parse_keys = {}
	for k, _ in pairs(parse_cache) do
		table.insert(parse_keys, k)
	end
	local file_keys = {}
	for k, _ in pairs(file_lines_cache) do
		table.insert(file_keys, k)
	end
	return {
		parse_keys = parse_keys,
		file_keys = file_keys,
	}
end

return M
