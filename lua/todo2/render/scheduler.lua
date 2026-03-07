-- lua/todo2/render/scheduler.lua
-- 统一调度 + 按任务 ID 增量渲染（唯一方案）

local M = {}

local rendering = {}
local pending = {}
local DEBOUNCE = 10

local parse_cache = {}
local CACHE_TTL = 5000

local parser = nil

---------------------------------------------------------------------
-- 获取解析树（带缓存）
---------------------------------------------------------------------
function M.get_parse_tree(path, force_refresh)
	if not path or path == "" then
		return {}, {}, {}
	end

	if not parser then
		parser = require("todo2.core.parser")
	end

	local now = vim.loop.now()
	local cached = parse_cache[path]

	if not force_refresh and cached and (now - cached.time) < CACHE_TTL then
		return cached.tasks, cached.roots, cached.id_to_task
	end

	local tasks, roots, id_to_task = parser.parse_file(path, force_refresh)

	parse_cache[path] = {
		tasks = tasks or {},
		roots = roots or {},
		id_to_task = id_to_task or {},
		time = now,
	}

	return tasks or {}, roots or {}, id_to_task or {}
end

---------------------------------------------------------------------
-- 缓存失效
---------------------------------------------------------------------
function M.invalidate_cache(path)
	if path then
		parse_cache[path] = nil
	else
		parse_cache = {}
	end
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
-- 核心刷新（唯一方案：增量优先 + 显式全量）
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
		rendering[bufnr] = nil
		return 0
	end

	local is_todo = path:match("%.todo%.md$")

	-----------------------------------------------------------------
	-- 获取旧解析树（用于 diff）
	-----------------------------------------------------------------
	local old = {}
	if parse_cache[path] and parse_cache[path].id_to_task then
		old = parse_cache[path].id_to_task
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
	local tasks, roots, id_to_task = M.get_parse_tree(path, opts.force_refresh)

	-----------------------------------------------------------------
	-- TODO 文件：按任务 ID 增量渲染
	-----------------------------------------------------------------
	if is_todo then
		local todo_render = require("todo2.render.todo_render")
		local conceal = require("todo2.render.conceal")

		-- 显式全量
		if opts.force_refresh or vim.tbl_isempty(old) then
			local count = todo_render.render(bufnr, { force_refresh = true })
			conceal.apply_smart_conceal(bufnr)
			rendering[bufnr] = nil
			return count
		end

		-- 增量
		local changed = diff_parse_tree(old, id_to_task)
		local count = 0

		for id, _ in pairs(changed) do
			local task = id_to_task[id]
			if task and task.line_num then
				pcall(todo_render.render_task, bufnr, task)
				count = count + 1
			end
		end

		conceal.apply_smart_conceal(bufnr)

		rendering[bufnr] = nil
		return count
	end

	-----------------------------------------------------------------
	-- CODE 文件：按任务 ID 增量渲染
	-----------------------------------------------------------------
	local code_render = require("todo2.render.code_render")

	-- 显式全量
	if opts.force_refresh then
		code_render.render_code_status(bufnr)
		rendering[bufnr] = nil
		return 0
	end

	-- 如果事件传入 changed_id，则按任务 ID 渲染
	if opts.changed_id then
		pcall(code_render.render_task_id, opts.changed_id)
		rendering[bufnr] = nil
		return 1
	end

	-- 否则全量（事件系统可传 changed_id）
	code_render.render_code_status(bufnr)
	rendering[bufnr] = nil
	return 0
end

---------------------------------------------------------------------
-- pending
---------------------------------------------------------------------
function M.refresh_all(opts)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			M.refresh(bufnr, opts)
		end
	end
end

function M.clear()
	rendering = {}
	pending = {}
	parse_cache = {}
end

return M
