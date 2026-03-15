-- lua/todo2/render/scheduler.lua
-- 最终版：不覆盖状态，不参与状态逻辑，只负责结构解析与增量刷新

local core = require("todo2.store.link.core")

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
-- 文件行缓存
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
-- 解析缓存
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
		return cached.tasks, cached.roots, cached.id_to_task, cached.archive_trees
	end

	local lines = M.get_file_lines(abs, force_refresh)
	local raw_tasks, roots, raw_id_to_task, archive_trees = parser.parse_lines(abs, lines)

	-----------------------------------------------------------------
	-- ⭐ 合并内部存储数据（不覆盖状态）
	-----------------------------------------------------------------
	local merged_tasks = {}
	local merged_id_to_task = {}

	for _, task in ipairs(raw_tasks or {}) do
		local merged = vim.deepcopy(task)

		if task.id then
			local t = core.get_task(task.id)
			if t then
				-- ⭐ 不覆盖状态，不写 merged.status
				merged.store = {
					id = t.id,
					status = t.core.status, -- 渲染层会用，但 scheduler 不参与逻辑
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

	return merged_tasks, roots, merged_id_to_task, archive_trees
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
-- ⭐ diff：只比较结构，不比较状态
---------------------------------------------------------------------
local function task_changed(a, b)
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
	return false
end

local function diff_parse_tree(old, new)
	local changed = {}

	for id, new_task in pairs(new) do
		local old_task = old[id]
		if not old_task or task_changed(old_task, new_task) then
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
-- 渲染刷新
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

	local abs = get_absolute_path(path)
	local old = {}
	if parse_cache[abs] and parse_cache[abs].id_to_task then
		old = parse_cache[abs].id_to_task
	end

	if opts.from_event then
		M.invalidate_cache(path)
	end

	local tasks, roots, id_to_task = M.get_parse_tree(path, opts.force_refresh)

	-----------------------------------------------------------------
	-- TODO 文件：增量渲染
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

		local changed = diff_parse_tree(old, id_to_task)
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

		if conceal and conceal.apply_smart_conceal then
			if #changed_lines > 0 then
				pcall(conceal.apply_smart_conceal, bufnr, changed_lines)
			else
				pcall(conceal.apply_smart_conceal, bufnr)
			end
		end

		return finish(bufnr, count)
	end

	-----------------------------------------------------------------
	-- CODE 文件：增量渲染
	-----------------------------------------------------------------
	local code_render = require("todo2.render.code_render")
	local conceal = require("todo2.render.conceal")

	if opts.force_refresh then
		pcall(code_render.render_code_status, bufnr)
		if conceal and conceal.apply_smart_conceal then
			pcall(conceal.apply_smart_conceal, bufnr)
		end
		return finish(bufnr, 0)
	end

	if opts.changed_id then
		pcall(code_render.render_task_id, opts.changed_id)
		return finish(bufnr, 1)
	end

	pcall(code_render.render_code_status, bufnr)
	if conceal and conceal.apply_smart_conceal then
		pcall(conceal.apply_smart_conceal, bufnr)
	end
	return finish(bufnr, 0)
end

---------------------------------------------------------------------
-- 其他接口
---------------------------------------------------------------------
function M.refresh_after_edit(bufnr, opts)
	opts = opts or {}
	opts.from_event = true
	opts.force_refresh = true
	return M.refresh(bufnr, opts)
end

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
