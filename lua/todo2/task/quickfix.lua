-- lua/todo2/task/quickfix.lua
-- 把「当前看到的任务」固定到 quickfix：过滤结果不再随抽屉/缓冲区的开关消失，
-- 并直接复用 quickfix 的跳转、:cdo、历史列表等能力。
--
-- 三个入口共享同一套展示/定位规则：
--   buffer_items(bufnr)  —— 当前 TODO 文件（尊重缓冲区上的筛选）
--   groups_items(groups) —— 抽屉的可见任务（由 drawer 计算 visible 集合）
--   calendar_items(...)  —— 日历当前月（已按日历筛选过滤）
--
-- 定位顺序与插件其它跳转一致：自身且未失联的代码锚点 → TODO 行。

local M = {}

local buffer = require("todo2.utils.buffer")
local checkbox = require("todo2.render.checkbox")
local config = require("todo2.config")
local core = require("todo2.store.task.core")
local due_utils = require("todo2.utils.due")
local file = require("todo2.utils.file")
local filter = require("todo2.render.filter")
local scheduler = require("todo2.render.scheduler")
local tags_utils = require("todo2.utils.tags")
local tree = require("todo2.utils.tree")
local win_util = require("todo2.utils.win")

local function node_key(node)
	return node.id or node
end

---把解析树节点转成筛选器需要的「类 store 任务」：行内字段优先，store 补路径/git 信息。
---@param node table
---@return table
local function filter_task(node)
	local stored = node._task or core.get_task(node.id)
	local copy = {}
	if stored then
		for k, v in pairs(stored) do
			copy[k] = v
		end
	end
	local data = {}
	for k, v in pairs((stored and stored.core) or {}) do
		data[k] = v
	end
	-- 解析树是 buffer 真源：刚编辑过、store 还没跟上的行也要被正确筛到
	data.content = node.content or data.content
	data.status = node.status or data.status
	data.due = node.due or data.due
	data.start = node.start or data.start
	data.tags = node.tags or data.tags
	copy.core = data
	copy.locations = copy.locations or {}
	if not copy.locations.todo and node.path then
		copy.locations.todo = { path = node.path, line = node.line_num }
	end
	return copy
end

---树上的筛选可见性（与 TODO 文件/抽屉同一语义）：
---自身命中；scope:tree 时祖先命中的子树随行；任一后代命中 → 祖先作为上下文可见。
---@param roots table[]
---@param spec Todo2FilterSpec
---@return table<any, boolean>
local function tree_visibility(roots, spec)
	local ctx = filter.build_git_context(spec)
	local include_descendants = filter.has_tree_scope(spec)
	local visible = {}
	local function mark(node, inherited)
		local self_match = filter.task_matches(filter_task(node), spec, ctx)
		local self_visible = self_match or (include_descendants and inherited == true) or false
		local child_visible = false
		for _, child in ipairs(node.children or {}) do
			if mark(child, self_visible) then
				child_visible = true
			end
		end
		local vis = self_visible or child_visible
		visible[node_key(node)] = vis
		return vis
	end
	for _, root in ipairs(roots) do
		mark(root, false)
	end
	return visible
end

---qf 行文本：树形缩进 + 状态图标 + 内容 + 到期日 + 标签 + 锚点标记。
---@param node table
---@param depth integer
---@param stack boolean[]
---@param inherited_code boolean 祖先链上是否有可用的代码锚点
---@return string text
---@return boolean effective_code
local function display_text(node, depth, stack, inherited_code)
	local t = filter_task(node)
	local core_data = t.core or {}
	local parts = { tree.build_indent(depth, stack) }

	if config.get("viewer_show_icons") ~= false then
		local icon = checkbox.get(core_data.status)
		if icon ~= "" then
			parts[#parts + 1] = icon .. " "
		end
	end
	parts[#parts + 1] = core_data.content or node.content or ""

	if core_data.due then
		parts[#parts + 1] = " " .. due_utils.format_short(core_data.due)
	end
	parts[#parts + 1] = tags_utils.format(core_data.tags)

	local code = t.locations and t.locations.code
	local own_usable = code ~= nil and code.path ~= nil and not core.is_anchor_lost(t)
	local effective = own_usable or inherited_code
	if own_usable then
		parts[#parts + 1] = " " .. (config.get("icons.drawer.code_link") or "")
	elseif effective then
		parts[#parts + 1] = " " .. (config.get("icons.drawer.code_link_inherited") or "")
	end
	return table.concat(parts), effective
end

---定位：自身代码锚点优先（插件惯例），否则 TODO 行。
---@param t table|nil 类 store 任务
---@param node table|nil 解析树节点
---@param path string|nil 兜底 TODO 路径
---@param line integer|nil 兜底 TODO 行
---@return string|nil filename
---@return integer lnum
local function location_of(t, node, path, line)
	local code = t and t.locations and t.locations.code
	if code and code.path and code.line and t and not core.is_anchor_lost(t) then
		return code.path, code.line
	end
	local todo = t and t.locations and t.locations.todo
	if todo and todo.path and todo.line then
		return todo.path, todo.line
	end
	if node and node.path and node.line_num then
		return node.path, node.line_num
	end
	return path, line or 1
end

---@param roots table[]
---@param opts { visible?: table<any, boolean>, path?: string }|nil
---@return table[] quickfix items
local function items_from_roots(roots, opts)
	opts = opts or {}
	local visible = opts.visible
	local items = {}

	local function walk(node, depth, stack, inherited_code)
		if visible and not visible[node_key(node)] then
			return
		end
		local cur = {}
		for i = 1, depth do
			cur[i] = stack[i]
		end
		local children = node.children or {}

		local text, effective = display_text(node, depth, cur, inherited_code)
		local t = filter_task(node)
		local filename, lnum = location_of(t, node, opts.path)
		if filename and filename ~= "" then
			items[#items + 1] = {
				filename = filename,
				lnum = lnum or 1,
				col = 0,
				text = text,
				user_data = node.id and { id = node.id } or nil,
			}
		end

		for i, child in ipairs(children) do
			local child_stack = {}
			for k = 1, depth do
				child_stack[k] = cur[k]
			end
			child_stack[depth + 1] = (i == #children)
			walk(child, depth + 1, child_stack, effective)
		end
	end

	for i, root in ipairs(roots) do
		walk(root, 0, {}, false)
	end
	return items
end

---TODO 文件 → quickfix items（使用该缓冲区当前激活的筛选，未筛选则全部任务）。
---@param bufnr number
---@return table[]|nil items
---@return string|nil title
function M.buffer_items(bufnr)
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	local path = buffer.get_path(bufnr)
	if not file.is_todo_file(path) then
		return nil
	end
	local _, roots = scheduler.get_parse_tree(path)
	local spec = filter.active(bufnr)
	local visible
	if spec and not filter.is_empty(spec) then
		visible = tree_visibility(roots, spec)
	end
	local items = items_from_roots(roots, { visible = visible, path = path })
	local title = "todo2 · " .. file.basename(path)
	if spec and not filter.is_empty(spec) then
		title = title .. " · " .. filter.describe(spec)
	end
	return items, title
end

---抽屉分组 → quickfix items。visible 为 nil 时导出全部任务。
---@param groups table[]
---@param visible table<any, boolean>|nil
---@return table[] items
function M.groups_items(groups, visible)
	local items = {}
	for _, group in ipairs(groups) do
		vim.list_extend(items, items_from_roots(group.roots, {
			visible = visible,
			path = group.archived and nil or group.file,
		}))
	end
	return items
end

---日历当前月 → quickfix items。同一天内同一任务只出现一次（承诺层优先）。
---活动层日期来自「最后修改日」，所以同一任务可能在月内多个日期各出现一次。
---@param entries Todo2CalendarEntries
---@return table[] items
function M.calendar_items(entries)
	local commits = (entries and entries.commits) or {}
	-- 月视图聚合结果叫 activities，当日列表叫 marks；两边都接受
	local marks = (entries and (entries.activities or entries.marks)) or {}
	local days, seen_day = {}, {}
	for day in pairs(commits) do
		days[#days + 1] = day
		seen_day[day] = true
	end
	for day in pairs(marks) do
		if not seen_day[day] then
			days[#days + 1] = day
		end
	end
	table.sort(days)

	local commit_icon = config.get("icons.calendar.commitment") or ""
	local mark_icon = config.get("icons.calendar.mark") or ""
	local items = {}
	for _, day in ipairs(days) do
		local seen = {}
		local function add(list, is_commit)
			for _, entry in ipairs(list or {}) do
				local key = entry.id or (entry.path .. ":" .. tostring(entry.line))
				if not seen[key] then
					seen[key] = true
					local t = entry.id and core.get_task(entry.id) or nil
					local filename, lnum = location_of(t, nil, entry.path, entry.line)
					if filename and filename ~= "" then
						local text = string.format("%02d %s %s", day, is_commit and commit_icon or mark_icon, entry.content or "")
						local tags = t and t.core and t.core.tags or nil
						text = text .. tags_utils.format(tags)
						items[#items + 1] = {
							filename = filename,
							lnum = lnum or 1,
							col = 0,
							text = text,
							user_data = entry.id and { id = entry.id, kind = entry.kind } or nil,
						}
					end
				end
			end
		end
		add(commits[day], true)
		add(marks[day], false)
	end
	return items
end

---推入 quickfix 并打开。空列表只提示，不清掉旧列表（用户可能还想回去）。
---@param items table[]
---@param title string|nil
---@return boolean opened
function M.push(items, title)
	if not items or #items == 0 then
		vim.notify("todo2: no tasks to show", vim.log.levels.INFO)
		return false
	end
	local what = { title = title or "todo2", items = items }
	local ok = pcall(vim.fn.setqflist, {}, " ", what)
	if not ok then
		-- 老版本 Neovim：退化为无标题写入
		vim.fn.setqflist(items, "r")
	end
	win_util.copen()
	return true
end

return M
