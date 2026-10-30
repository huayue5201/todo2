-- lua/todo2/ui/calendar/service.lua
--- 月历的数据层：把「当前项目里有到期日的活跃任务」按月聚合。
---
--- 只读：不解析、不写回。任务真源仍是 TODO 文件（parse tree 由 render.scheduler 缓存）。

local M = {}

local due_utils = require("todo2.utils.due")
local fm = require("todo2.ui.file_manager")
local project_utils = require("todo2.utils.project")
local scheduler = require("todo2.render.scheduler")
local types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local filter = require("todo2.render.filter")
local config = require("todo2.config")
local model = require("todo2.ui.calendar.model")

local URGENCY_RANK = { overdue = 1, today = 2, soon = 3, future = 4 }
local DONE_RANK = 50 -- 已完成任务排在所有未完成之后

local CACHE_TTL = 3 -- 秒；同一月内连续 j/k 不重复遍历任务树
local _cache = {}

---清空聚合缓存（外部改了任务后可主动调用；缓存键含项目名，切项目也不会串）
function M.invalidate()
	_cache = {}
end

---把解析树节点当成 store 任务喂给筛选器（store 里查不到时退化为行内信息）
---@param node table
---@param status string|nil checkbox 解出的状态（`[ ]` 会解出 nil，这里补默认值）
---@return table
local function task_of(node, status)
	local ok, task = pcall(core.get_task, node.id)
	if ok and task then
		-- 到期日/状态以解析树（buffer 真源）为准：store 可能还没跟上刚编辑的那一行，
		-- 否则 `due:overdue` 这类筛选会漏掉任务。浅拷贝，避免改到 store 里的活对象
		local core_copy = {}
		for k, v in pairs(task.core or {}) do
			core_copy[k] = v
		end
		core_copy.due = node.due or core_copy.due
		core_copy.status = status or core_copy.status
		local copy = {}
		for k, v in pairs(task) do
			copy[k] = v
		end
		copy.core = core_copy
		return copy
	end
	return {
		core = { status = status or config.get_default_status(), due = node.due, tags = node.tags },
		locations = { todo = { path = node.path } },
	}
end

---@param node table
---@param out table<integer, table[]>
---@param prefix string 形如 "2026-10-"
---@param opts table { hide_completed?: boolean, spec?: Todo2FilterSpec|nil, ctx?: table }
local function walk(node, out, prefix, opts, ctx)
	local due = node.due
	if due and node.checkbox and type(due) == "string" and due:sub(1, #prefix) == prefix then
		local status = types.checkbox_to_status(node.checkbox:lower())
		local completed = types.is_completed_status(status)
		-- 归档任务（checkbox `[>]`）默认不进日历：归档即「移出视野」，与抽屉默认一致
		local archived = status == types.STATUS.ARCHIVED
		local day = tonumber(due:sub(9, 10))
		-- 校验真实日子：`@2026-02-31` 这种脏日期不能塞进永远渲染不到的格子
		local max_day = model.days_in_month(tonumber(due:sub(1, 4)), tonumber(due:sub(6, 7)))
		local visible = not archived and not (opts.hide_completed and completed)
		if visible and opts.spec and not filter.task_matches(task_of(node, status), opts.spec, ctx) then
			visible = false
		end
		if visible and day and day >= 1 and day <= max_day then
			out[day] = out[day] or {}
			local urgency = due_utils.urgency(due, status)
			table.insert(out[day], {
				content = node.content or "",
				id = node.id,
				path = node.path,
				line = node.line_num,
				due = due,
				status = status,
				completed = completed,
				urgency = urgency,
				hl = due_utils.hl(due, status) or "TodoDue",
			})
		end
	end
	for _, child in ipairs(node.children or {}) do
		walk(child, out, prefix, opts, ctx)
	end
end

local function sort_items(items)
	table.sort(items, function(a, b)
		local da, db = a.completed and DONE_RANK or 0, b.completed and DONE_RANK or 0
		if da ~= db then
			return da < db
		end
		local ra, rb = URGENCY_RANK[a.urgency] or 9, URGENCY_RANK[b.urgency] or 9
		if ra ~= rb then
			return ra < rb
		end
		if a.due ~= b.due then
			return a.due < b.due
		end
		return a.content < b.content
	end)
end

---过滤规格的可读描述（只用于缓存键，避免每次重算）
---@param spec Todo2FilterSpec|nil
---@return string
local function spec_key(spec)
	return spec and filter.describe(spec) or ""
end

---聚合某月的任务：`{[day] = item[]}`
---@param year integer
---@param month integer
---@param opts? { force_refresh?: boolean, hide_completed?: boolean, spec?: Todo2FilterSpec|nil }
---@return table<integer, table[]>
function M.month_items(year, month, opts)
	opts = opts or {}
	-- 缓存键必须带项目名：TODO 文件是「每项目一套」的；筛选条件与「是否含已完成」
	-- 同样影响结果集，必须进键，否则切换筛选会读到上一次的聚合
	local key = string.format(
		"%s|%04d-%02d|%s|%s",
		project_utils.get_project_name() or "",
		year,
		month,
		opts.hide_completed and "hide" or "all",
		spec_key(opts.spec)
	)
	local cached = _cache[key]
	if not opts.force_refresh and cached and (os.time() - cached.ts) < CACHE_TTL then
		return cached.data
	end

	local out = {}
	local ok, files = pcall(function()
		return fm.get_todo_files(project_utils.get_project_name()) or {}
	end)
	if not ok then
		vim.notify("todo2 calendar: failed to read TODO files", vim.log.levels.WARN)
		return out
	end

	local prefix = string.format("%04d-%02d-", year, month)
	local ctx = filter.build_git_context(opts.spec)
	local walk_opts = { hide_completed = opts.hide_completed and true or false, spec = opts.spec }
	for _, path in ipairs(files) do
		local _, roots = scheduler.get_parse_tree(path)
		for _, root in ipairs(roots or {}) do
			walk(root, out, prefix, walk_opts, ctx)
		end
	end

	for _, items in pairs(out) do
		sort_items(items)
	end

	_cache[key] = { ts = os.time(), data = out }
	return out
end

---某天的任务列表（已排序）
---@param year integer
---@param month integer
---@param day integer
---@param opts? table 同 month_items
---@return table[]
function M.day_items(year, month, day, opts)
	return M.month_items(year, month, opts)[day] or {}
end

---某天的任务计数：`{ todo = 未完成数, done = 已完成数 }`
---@param items table[]|nil
---@return { todo: integer, done: integer }
function M.counts(items)
	local out = { todo = 0, done = 0 }
	for _, item in ipairs(items or {}) do
		if item.completed then
			out.done = out.done + 1
		else
			out.todo = out.todo + 1
		end
	end
	return out
end

return M
