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

local URGENCY_RANK = { overdue = 1, today = 2, soon = 3, future = 4 }

local CACHE_TTL = 3 -- 秒；同一月内连续 j/k 不重复遍历任务树
local _cache = {}

---清空聚合缓存（外部改了任务后可主动调用）
function M.invalidate()
	_cache = {}
end

---@param node table
---@param out table<integer, table[]>
---@param prefix string 形如 "2026-10-"
local function walk(node, out, prefix)
	local due = node.due
	if due and node.checkbox and type(due) == "string" and due:sub(1, #prefix) == prefix then
		local status = types.checkbox_to_status(node.checkbox:lower())
		if not types.is_completed_status(status) then
			local day = tonumber(due:sub(9, 10))
			if day and day >= 1 and day <= 31 then
				out[day] = out[day] or {}
				local urgency = due_utils.urgency(due, status)
				table.insert(out[day], {
					content = node.content or "",
					id = node.id,
					path = node.path,
					line = node.line_num,
					due = due,
					status = status,
					urgency = urgency,
					hl = due_utils.hl(due, status) or "TodoDue",
				})
			end
		end
	end
	for _, child in ipairs(node.children or {}) do
		walk(child, out, prefix)
	end
end

local function sort_items(items)
	table.sort(items, function(a, b)
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

---聚合某月的任务：`{[day] = item[]}`
---@param year integer
---@param month integer
---@param opts? { force_refresh?: boolean }
---@return table<integer, table[]>
function M.month_items(year, month, opts)
	opts = opts or {}
	local key = string.format("%04d-%02d", year, month)
	local cached = _cache[key]
	if not opts.force_refresh and cached and (os.time() - cached.ts) < CACHE_TTL then
		return cached.data
	end

	local out = {}
	local ok, files = pcall(function()
		return fm.get_todo_files(project_utils.get_project_name()) or {}
	end)
	if not ok then
		return out
	end

	local prefix = key .. "-"
	for _, path in ipairs(files) do
		local _, roots = scheduler.get_parse_tree(path)
		for _, root in ipairs(roots or {}) do
			walk(root, out, prefix)
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
---@return table[]
function M.day_items(year, month, day)
	return M.month_items(year, month)[day] or {}
end

---某天的标记样式：取该日最紧急一条任务的高亮组（items 已按紧急度排序）
---@param items table[]|nil
---@return string|nil hl
function M.mark_of(items)
	if not items or #items == 0 then
		return nil
	end
	return items[1].hl
end

return M
