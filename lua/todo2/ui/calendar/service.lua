-- lua/todo2/ui/calendar/service.lua
--- 月历的数据层：把当前项目的任务按月聚合成**两层语义**的条目。
---
--- 两层语义（见 doc `todo2-concepts`）：
---   * 承诺 commit：有时间维度（due 或 start）的标记 → 落在该日期
---   * 活动 mark：任何被「碰过」的标记 → 落在它最后修改的日期
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
local DONE_RANK = 50 -- 已完成承诺排在所有未完成之后

local CACHE_TTL = 3 -- 秒；同一月内连续 j/k 不重复遍历任务树
local _cache = {}

---清空聚合缓存（外部改了任务后可主动调用；缓存键含项目名，切项目也不会串）
function M.invalidate()
	_cache = {}
end

---@class Todo2CalendarEntry
---@field content string
---@field id string
---@field path string
---@field line integer
---@field kind "commit"|"mark" 该条目这一层的语义
---@field plan "deadline"|"interval"|"planned"|"mark" 承诺形态
---@field due string|nil
---@field start string|nil 承诺日期（due 优先，退 start）
---@field touched string|nil 最后修改日期（YYYY-MM-DD）
---@field status string|nil
---@field completed boolean
---@field urgency string|nil
---@field hl string

---@class Todo2CalendarEntries
---@field commits table<integer, Todo2CalendarEntry[]>
---@field activities table<integer, Todo2CalendarEntry[]>
---@field undated Todo2CalendarEntry[] 既无时间维度又无时间戳的历史残渣

---把解析树节点当成 store 任务喂给筛选器（store 里查不到时退化为行内信息）
---@param node table
---@param status string|nil checkbox 解出的状态（`[ ]` 会解出 nil，这里补默认值）
---@return table
local function task_of(node, status)
	local ok, task = pcall(core.get_task, node.id)
	if ok and task then
		-- 时间字段/状态以解析树（buffer 真源）为准：store 可能还没跟上刚编辑的那一行，
		-- 否则 `due:overdue` 这类筛选会漏掉任务。浅拷贝，避免改到 store 里的活对象
		local core_copy = {}
		for k, v in pairs(task.core or {}) do
			core_copy[k] = v
		end
		core_copy.due = node.due or core_copy.due
		core_copy.start = node.start or core_copy.start
		core_copy.status = status or core_copy.status
		local copy = {}
		for k, v in pairs(task) do
			copy[k] = v
		end
		copy.core = core_copy
		return copy
	end
	return {
		core = { status = status or config.get_default_status(), due = node.due, start = node.start, tags = node.tags },
		locations = { todo = { path = node.path } },
	}
end

---时间戳 → YYYY-MM-DD（0 / nil 返回 nil）
---@param ts integer|nil
---@return string|nil
local function date_of(ts)
	ts = tonumber(ts)
	if not ts or ts <= 0 then
		return nil
	end
	return os.date("%Y-%m-%d", ts)
end

---承诺形态
---@param start string|nil
---@param due string|nil
---@return "deadline"|"interval"|"planned"|"mark"
local function plan_of(start, due)
	if due and start then
		return "interval"
	end
	if due then
		return "deadline"
	end
	if start then
		return "planned"
	end
	return "mark"
end

---@param entry Todo2CalendarEntry
---@param day integer
local function push(map, day, entry)
	map[day] = map[day] or {}
	table.insert(map[day], entry)
end

---@param node table
---@param out Todo2CalendarEntries
---@param year integer
---@param month integer
---@param opts table { hide_completed?: boolean, spec?: Todo2FilterSpec|nil }
---@param ctx table
local function walk(node, out, year, month, opts, ctx)
	local prefix = string.format("%04d-%02d-", year, month)
	if node.checkbox then
		local status = types.checkbox_to_status(node.checkbox:lower())
		local completed = types.is_completed_status(status)
		-- 归档任务默认不进日历：归档即「移出视野」，与抽屉默认一致
		local archived = status == types.STATUS.ARCHIVED
		local task = nil
		local function get_task()
			task = task or task_of(node, status)
			return task
		end

		local visible = not archived and not (opts.hide_completed and completed)

		-- 两层分别过筛：axis:commit / axis:activity 只保留对应层
		local function layer_visible(kind)
			if not visible then
				return false
			end
			if not opts.spec then
				return true
			end
			local copy = {}
			for k, v in pairs(get_task()) do
				copy[k] = v
			end
			copy.kind = kind
			return filter.task_matches(copy, opts.spec, ctx)
		end

		if visible then
			local core_data = get_task().core or {}
			local due = due_utils.is_date(core_data.due) and core_data.due or nil
			local start = due_utils.is_date(core_data.start) and core_data.start or nil
			if start and due and start > due then
				start = nil
			end
			-- urgency 只对"承诺的截止"有意义：只有 start 的任务是"已开始/未开始"，
			-- 不能用逾期红色（否则计划中的任务看起来像违约）。
			local urgency = due_utils.urgency(due, status)
			local hl = (due and due_utils.hl(due, status)) or (start and "TodoTime") or "TodoTime"
			-- 活动层 = 内容/锚点最后一次变化（content_updated），不是"任何字段被改过"，
			-- 否则改个到期日就把任务挪到今天的活动格。
			local ts = (task or {}).timestamps or {}
			local touched = date_of(ts.content_updated) or date_of(ts.updated) or date_of(ts.created)

			local entry = {
				content = node.content or "",
				id = node.id,
				path = node.path,
				line = node.line_num,
				due = due,
				start = start,
				touched = touched,
				status = status,
				completed = completed,
				urgency = urgency,
				hl = hl,
				plan = plan_of(start, due),
			}

			-- 承诺层：坐标 = due（有则优先），否则 start
			local commit_date = due or start
			local commit_ok = layer_visible("commit")
			local mark_ok = layer_visible("mark")
			if commit_date and commit_ok then
				if commit_date:sub(1, #prefix) == prefix then
					local day = tonumber(commit_date:sub(9, 10))
					local max_day = model.days_in_month(tonumber(commit_date:sub(1, 4)), tonumber(commit_date:sub(6, 7)))
					if day and day >= 1 and day <= max_day then
						entry.kind = "commit"
						push(out.commits, day, entry)
						-- 同一对象不要在两处共享 kind：活动层是另一份副本
						local mark_entry = vim.tbl_extend("force", {}, entry, { kind = "mark" })
						if mark_ok and touched and touched:sub(1, #prefix) == prefix then
							local mday = tonumber(touched:sub(9, 10))
							if mday then
								push(out.activities, mday, mark_entry)
							end
						end
					end
				elseif mark_ok and touched and touched:sub(1, #prefix) == prefix then
					local mday = tonumber(touched:sub(9, 10))
					if mday then
						local mark_entry = vim.tbl_extend("force", {}, entry, { kind = "mark" })
						push(out.activities, mday, mark_entry)
					end
				end
			elseif touched then
				-- 纯标记：只有活动层
				if mark_ok and touched:sub(1, #prefix) == prefix then
					local mday = tonumber(touched:sub(9, 10))
					if mday then
						local mark_entry = vim.tbl_extend("force", {}, entry, { kind = "mark" })
						push(out.activities, mday, mark_entry)
					end
				end
			else
				-- 既无时间维度、也没有任何时间戳（老数据）：进 undated 桶
				local mark_entry = vim.tbl_extend("force", {}, entry, { kind = "mark" })
				out.undated[#out.undated + 1] = mark_entry
			end
		end
	end

	for _, child in ipairs(node.children or {}) do
		walk(child, out, year, month, opts, ctx)
	end
end

---承诺排序：未完成在前 → 紧迫度 → 日期 → 内容
local function sort_commits(items)
	table.sort(items, function(a, b)
		local da, db = a.completed and DONE_RANK or 0, b.completed and DONE_RANK or 0
		if da ~= db then
			return da < db
		end
		local ra, rb = URGENCY_RANK[a.urgency] or 9, URGENCY_RANK[b.urgency] or 9
		if ra ~= rb then
			return ra < rb
		end
		if a.start ~= b.start then
			return (a.start or "") < (b.start or "")
		end
		return a.content < b.content
	end)
end

---活动排序：最近碰过的在前
local function sort_marks(items)
	table.sort(items, function(a, b)
		if a.completed ~= b.completed then
			return not a.completed
		end
		if a.touched ~= b.touched then
			return (a.touched or "") > (b.touched or "")
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

---聚合某月：承诺层 + 活动层 + undated 桶
---@param year integer
---@param month integer
---@param opts? { force_refresh?: boolean, hide_completed?: boolean, spec?: Todo2FilterSpec|nil }
---@return Todo2CalendarEntries
function M.month_entries(year, month, opts)
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

	---@type Todo2CalendarEntries
	local out = { commits = {}, activities = {}, undated = {} }
	local ok, files = pcall(function()
		return fm.get_todo_files(project_utils.get_project_name()) or {}
	end)
	if not ok then
		vim.notify("todo2 calendar: failed to read TODO files", vim.log.levels.WARN)
		return out
	end

	local ctx = filter.build_git_context(opts.spec)
	local walk_opts = { hide_completed = opts.hide_completed and true or false, spec = opts.spec }
	for _, path in ipairs(files) do
		local _, roots = scheduler.get_parse_tree(path)
		for _, root in ipairs(roots or {}) do
			walk(root, out, year, month, walk_opts, ctx)
		end
	end

	for _, items in pairs(out.commits) do
		sort_commits(items)
	end
	for _, items in pairs(out.activities) do
		sort_marks(items)
	end
	sort_marks(out.undated)

	_cache[key] = { ts = os.time(), data = out }
	return out
end

return M
