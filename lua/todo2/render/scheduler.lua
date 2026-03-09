-- lua/todo2/render/scheduler.lua
-- 统一调度 + 按任务 ID 增量渲染（增强版：文件行缓存 + 解析缓存 + 归档支持）

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
	-- expand ~ and make absolute canonical path
	path = path:gsub("^~", uv.os_homedir())
	local p = vim.fn.fnamemodify(path, ":p")
	-- try fs_realpath for symlink resolution; fallback to p
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

	local key = abs
	local entry = file_lines_cache[key]
	local ts = now_ms()

	if not force_refresh and entry and (ts - entry.time) < FILE_CACHE_TTL then
		return entry.lines
	end

	local ok, lines = pcall(vim.fn.readfile, abs)
	lines = ok and lines or {}
	file_lines_cache[key] = { lines = lines, time = ts }
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
-- 解析缓存接口（封装 parser.parse_file 或 parser.parse_lines）
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

	-- 优先通过 scheduler 的文件缓存读取文件行，再交给 parser.parse_lines（parser 为纯解析）
	local lines = M.get_file_lines(abs, force_refresh)
	local tasks, roots, id_to_task, archive_trees

	-- 如果 parser 提供 parse_lines（纯解析），优先使用；否则回退到 parse_file
	if parser.parse_lines then
		tasks, roots, id_to_task, archive_trees = parser.parse_lines(abs, lines)
	else
		-- 兼容旧版 parser.parse_file（会自行 readfile）
		tasks, roots, id_to_task, archive_trees = parser.parse_file(abs, force_refresh)
	end

	-- 记录文件 mtime（用于外部判断）
	local stat = uv.fs_stat(abs)
	local mtime = stat and stat.mtime and stat.mtime.sec or 0

	parse_cache[abs] = {
		tasks = tasks or {},
		roots = roots or {},
		id_to_task = id_to_task or {},
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
		M.invalidate_file_cache(nil)
	end
end

---------------------------------------------------------------------
-- 对外：按 bufnr 获取解析树（方便其他模块通过 scheduler 拿任务）
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
-- diff（按任务 ID）
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
	if a.status ~= b.status then
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
-- 渲染结束统一收尾（释放锁 + 处理 pending）
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
-- 核心刷新（增量优先 + 显式全量）
---------------------------------------------------------------------
function M.refresh(bufnr, opts)
	opts = opts or {}

	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	if rendering[bufnr] then
		-- 后来的覆盖前面的，保持最新意图
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
	-- 获取旧解析树（用于 diff）
	-----------------------------------------------------------------
	local abs = get_absolute_path(path)
	local old = {}
	if parse_cache[abs] and parse_cache[abs].id_to_task then
		old = parse_cache[abs].id_to_task
	end

	-----------------------------------------------------------------
	-- from_event：只重新解析，不强制全量
	-----------------------------------------------------------------
	if opts.from_event then
		M.invalidate_cache(path)
	end

	-----------------------------------------------------------------
	-- 获取新解析树
	-----------------------------------------------------------------
	local tasks, roots, id_to_task, archive_trees = M.get_parse_tree(path, opts.force_refresh)

	-----------------------------------------------------------------
	-- TODO 文件：按任务 ID 增量渲染
	-----------------------------------------------------------------
	if is_todo then
		local todo_render = require("todo2.render.todo_render")
		local conceal = require("todo2.render.conceal")

		-- 显式全量
		if opts.force_refresh or vim.tbl_isempty(old) then
			local count = todo_render.render(bufnr, { force_refresh = true })
			if conceal and conceal.apply_smart_conceal then
				pcall(conceal.apply_smart_conceal, bufnr)
			end
			return finish(bufnr, count)
		end

		-- 增量
		local changed = diff_parse_tree(old, id_to_task)
		local count = 0
		local changed_lines = {} -- ⭐ 收集变化的行号

		for id, _ in pairs(changed) do
			local task = id_to_task[id]
			if task and task.line_num then
				pcall(todo_render.render_task, bufnr, task)
				table.insert(changed_lines, task.line_num) -- ⭐ 记录行号
				count = count + 1
			end
		end

		-- ⭐ 去重并排序行号
		if #changed_lines > 0 then
			local unique = {}
			for _, lnum in ipairs(changed_lines) do
				unique[lnum] = true
			end
			changed_lines = vim.tbl_keys(unique)
			table.sort(changed_lines)

			if conceal and conceal.apply_smart_conceal then
				pcall(conceal.apply_smart_conceal, bufnr, changed_lines) -- ⭐ 增量更新 conceal
			end
		else
			-- 没有变化，但为了保险还是刷新一下
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

	-- 显式全量
	if opts.force_refresh then
		pcall(code_render.render_code_status, bufnr)
		if conceal and conceal.apply_smart_conceal then
			pcall(conceal.apply_smart_conceal, bufnr) -- ⭐ 全量刷新 conceal
		end
		return finish(bufnr, 0)
	end

	-- 如果事件传入 changed_id，则按任务 ID 渲染
	if opts.changed_id then
		pcall(code_render.render_task_id, opts.changed_id)

		-- ⭐ 获取代码标记的行号并增量更新 conceal
		local link_mod = require("todo2.store.link")
		local code = link_mod.get_code(opts.changed_id, { verify_line = true })
		if code and code.line_num and conceal and conceal.apply_smart_conceal then
			pcall(conceal.apply_smart_conceal, bufnr, { code.line_num })
		end

		return finish(bufnr, 1)
	end

	-- 否则全量
	pcall(code_render.render_code_status, bufnr)
	if conceal and conceal.apply_smart_conceal then
		pcall(conceal.apply_smart_conceal, bufnr) -- ⭐ 全量刷新 conceal
	end
	return finish(bufnr, 0)
end

---------------------------------------------------------------------
-- 针对“编辑后”的刷新入口（方便其他模块调用）
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
