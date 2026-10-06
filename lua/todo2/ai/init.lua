-- lua/todo2/ai/context.lua
-- 任务上下文组装层：把任务（代码锚点 + 任务树 + 正文 + 代码）整理成可喂给
-- AI / 外部工具的结构。
--
-- 与具体 AI 客户端解耦：只负责产出数据（build）与两种渲染（to_markdown / to_json）。
-- 上层（编辑器内 AI 插件适配、MCP server、CLI pipe）都消费这一层。

local M = {}

local core = require("todo2.store.task.core")
local query = require("todo2.store.task.query")
local relation = require("todo2.store.task.relation")
local config = require("todo2.config")
local file = require("todo2.utils.file")
local tags_utils = require("todo2.utils.tags")

---------------------------------------------------------------------
-- 选项
---------------------------------------------------------------------

---@class todo2.ContextOptions
---@field include_code? boolean        是否附带代码正文
---@field include_ancestors? boolean   是否附带祖先链
---@field include_children? boolean|integer 子树层级：true=全部，数字=层数
---@field max_code_lines? integer     代码正文最多取多少行（0 表示不限）

---@param opts? todo2.ContextOptions
---@return todo2.ContextOptions
local function normalize_opts(opts)
	local cfg = config.get("ai") or {}
	local merged = vim.tbl_extend("force", cfg, opts or {})
	return {
		include_code = merged.include_code ~= false,
		include_ancestors = merged.include_ancestors ~= false,
		include_children = merged.include_children == nil and 1 or merged.include_children,
		max_code_lines = merged.max_code_lines or 0,
	}
end

---------------------------------------------------------------------
-- 代码块正文
---------------------------------------------------------------------

--- 取代码块源码（优先已加载 buffer，回退磁盘）。超长块按 max_lines 截断。
---@param loc table 代码位置（含 block_start / block_end）
---@param max_lines integer
---@return string|nil
local function block_source(loc, max_lines)
	local start_line = tonumber(loc.block_start) or tonumber(loc.line)
	local end_line = tonumber(loc.block_end) or tonumber(loc.line)
	if not start_line or not end_line or end_line < start_line then
		return nil
	end

	local lines = file.read_lines_smart(loc.path)
	if not lines or #lines == 0 then
		return nil
	end

	end_line = math.min(end_line, #lines)
	local slice = {}
	for i = start_line, end_line do
		slice[#slice + 1] = lines[i]
	end

	if max_lines and max_lines > 0 and #slice > max_lines then
		local truncated = {}
		for i = 1, max_lines do
			truncated[i] = slice[i]
		end
		truncated[#truncated + 1] = string.format("…（已截断，共 %d 行）", #slice)
		slice = truncated
	end

	return table.concat(slice, "\n")
end

---------------------------------------------------------------------
-- 组装
---------------------------------------------------------------------

---@param t table 完整任务对象
---@return table
local function summarize(t)
	return { id = t.id, content = t.core.content, status = t.core.status, tags = t.core.tags or {} }
end

--- 递归收集子树（depth 为 nil 表示不限层级）。
---@param id string
---@param depth integer|nil
---@return table[]
local function collect_children(id, depth)
	local out = {}
	for _, cid in ipairs(relation.get_child_ids(id)) do
		local t = core.get_task(cid)
		if t then
			local node = summarize(t)
			if depth == nil or depth > 0 then
				local kids = collect_children(cid, depth and (depth - 1) or nil)
				if #kids > 0 then
					node.children = kids
				end
			end
			out[#out + 1] = node
		end
	end
	return out
end

--- 组装单个任务的上下文。
---@param id string
---@param opts? todo2.ContextOptions
---@return table|nil
function M.build(id, opts)
	opts = normalize_opts(opts)
	local task = core.get_task(id)
	if not task then
		return nil
	end

	local bundle = {
		id = id,
		content = task.core.content,
		status = task.core.status,
		tags = task.core.tags or {},
	}

	if task.core.description and task.core.description ~= "" then
		bundle.description = task.core.description
	end
	if task.timestamps then
		bundle.created = task.timestamps.created
		bundle.updated = task.timestamps.updated
		if task.timestamps.completed then
			bundle.completed = task.timestamps.completed
		end
		if task.timestamps.archived then
			bundle.archived = task.timestamps.archived
		end
	end

	if task.locations and task.locations.todo then
		bundle.todo = { path = task.locations.todo.path, line = task.locations.todo.line }
	end

	-- 有效代码锚点：自身优先，否则继承自最近的父任务（补充任务）
	local loc, inherited = query.resolve_code_location(id)
	if loc then
		local anchor = {
			source = inherited and "inherited" or "own",
			state = inherited and "inherited" or core.anchor_state(task),
			path = loc.path,
			line = loc.line,
		}
		local ctx = loc.context or {}
		anchor.block = {
			type = ctx.type,
			name = ctx.name,
			signature = ctx.signature,
			start_line = loc.block_start or loc.line,
			end_line = loc.block_end or loc.line,
		}
		if opts.include_code then
			anchor.code = block_source(loc, opts.max_code_lines)
		end
		bundle.anchor = anchor
	elseif task.locations and task.locations.code then
		-- 自身锚点存在但已失联：只保留状态与最后已知位置，不给代码
		local cl = task.locations.code
		bundle.anchor = { source = "own", state = "lost", path = cl.path, line = cl.line }
	end

	if opts.include_ancestors then
		local ancestors = {}
		for _, aid in ipairs(relation.get_ancestors(id)) do
			local t = core.get_task(aid)
			if t then
				ancestors[#ancestors + 1] = summarize(t)
			end
		end
		if #ancestors > 0 then
			bundle.ancestors = ancestors
		end
	end

	if opts.include_children then
		local depth = opts.include_children == true and nil or opts.include_children
		local children = collect_children(id, depth)
		if #children > 0 then
			bundle.children = children
		end
	end

	return bundle
end
---------------------------------------------------------------------
-- 渲染
---------------------------------------------------------------------

---@param path string
---@return string
local function code_fence_lang(path)
	local ok, ft = pcall(vim.filetype.match, { filename = path })
	return (ok and type(ft) == "string" and ft ~= "") and ft or ""
end

---@param bundle table
---@return string
function M.to_markdown(bundle)
	local out = {}

	out[#out + 1] = string.format("# Task %s: %s", bundle.id, bundle.content or "")
	out[#out + 1] = ""
	out[#out + 1] = "- status: " .. (bundle.status or "?")
	if bundle.tags and #bundle.tags > 0 then
		out[#out + 1] = "- tags: " .. table.concat(bundle.tags, ", ")
	end

	local a = bundle.anchor
	if a then
		local line = {}
		line[#line + 1] = a.source == "inherited" and "inherited" or (a.state or "?")
		if a.path then
			line[#line + 1] = string.format("%s:%s", a.path, tostring(a.line))
		end
		local b = a.block
		if b and b.name then
			line[#line + 1] = (b.type and (b.type .. " ") or "") .. b.name
		end
		out[#out + 1] = "- code: " .. table.concat(line, " · ")
	end
	if bundle.todo then
		out[#out + 1] = string.format("- todo: %s:%s", bundle.todo.path, tostring(bundle.todo.line))
	end

	if bundle.description then
		out[#out + 1] = ""
		out[#out + 1] = "## Description"
		out[#out + 1] = bundle.description
	end

	if bundle.ancestors and #bundle.ancestors > 0 then
		out[#out + 1] = ""
		out[#out + 1] = "## Parent chain"
		for i, p in ipairs(bundle.ancestors) do
			out[#out + 1] = string.format("%s- [%s] %s (%s)", string.rep("  ", i - 1), p.status, p.content, p.id)
		end
	end

	if bundle.children and #bundle.children > 0 then
		out[#out + 1] = ""
		out[#out + 1] = "## Subtasks"
		local function rec(nodes, depth)
			for _, n in ipairs(nodes) do
				out[#out + 1] = string.format("%s- [%s] %s (%s)", string.rep("  ", depth), n.status, n.content, n.id)
				if n.children then
					rec(n.children, depth + 1)
				end
			end
		end
		rec(bundle.children, 0)
	end

	if a and a.code and a.code ~= "" then
		local b = a.block or {}
		local range = (b.start_line and b.end_line)
				and string.format("%s:%d-%d", a.path, b.start_line, b.end_line)
			or a.path
		out[#out + 1] = ""
		out[#out + 1] = "## Code (" .. range .. ")"
		out[#out + 1] = "```" .. code_fence_lang(a.path)
		out[#out + 1] = a.code
		out[#out + 1] = "```"
	end

	return table.concat(out, "\n")
end

---@param bundle table
---@return string
function M.to_json(bundle)
	return vim.json.encode(bundle)
end

---------------------------------------------------------------------
-- 项目级清单 / 树
---------------------------------------------------------------------

--- 当前项目的 TODO 文件解析结果（不含归档区）。
---@return table[] groups { path, roots }
local function project_groups()
	local fm = require("todo2.ui.file_manager")
	local project_utils = require("todo2.utils.project")
	local scheduler = require("todo2.render.scheduler")

	local groups = {}
	for _, path in ipairs(fm.get_todo_files(project_utils.get_project_name())) do
		local _, roots = scheduler.get_parse_tree(path)
		if roots and #roots > 0 then
			groups[#groups + 1] = { path = path, roots = roots }
		end
	end
	return groups
end

--- 任务摘要 + 有效锚点（不含代码正文）。
---@param t table
---@param id string
---@return table
local function anchor_summary(t, id)
	local item = { id = id, content = t.core.content, status = t.core.status, tags = t.core.tags or {} }
	local loc, inherited = query.resolve_code_location(id)
	if loc then
		item.anchor = {
			source = inherited and "inherited" or "own",
			state = inherited and "inherited" or core.anchor_state(t),
			path = loc.path,
			line = loc.line,
		}
	elseif t.locations and t.locations.code then
		item.anchor = { source = "own", state = "lost", path = t.locations.code.path, line = t.locations.code.line }
	end
	return item
end

--- 项目任务清单（摘要，不含代码正文）。
---@param opts? { status?: string, has_anchor?: boolean, tag?: string }
---@return table[]
function M.list(opts)
	opts = opts or {}
	local out, seen = {}, {}

	local function visit(id)
		if not id or seen[id] then
			return
		end
		seen[id] = true
		local t = core.get_task(id)
		if not t or (opts.status and t.core.status ~= opts.status) then
			return
		end
		if opts.tag and not tags_utils.contains(t.core.tags, opts.tag) then
			return
		end
		local item = anchor_summary(t, id)
		if opts.has_anchor == nil or (item.anchor ~= nil) == opts.has_anchor then
			out[#out + 1] = item
		end
	end

	for _, g in ipairs(project_groups()) do
		local function walk(node)
			visit(node.id)
			for _, c in ipairs(node.children or {}) do
				walk(c)
			end
		end
		for _, r in ipairs(g.roots) do
			walk(r)
		end
	end

	table.sort(out, function(a, b)
		return (a.content or "") < (b.content or "")
	end)
	return out
end

--- 项目任务树（按 TODO 文件分组，摘要）。
---@return { files: table[] }
function M.tree()
	local function node(n)
		if not n.id then
			return nil
		end
		local t = core.get_task(n.id)
		local item = { id = n.id, content = n.content }
		if t then
			item.status = t.core.status
			item.tags = t.core.tags or {}
		end
		local kids = {}
		for _, c in ipairs(n.children or {}) do
			local k = node(c)
			if k then
				kids[#kids + 1] = k
			end
		end
		if #kids > 0 then
			item.children = kids
		end
		return item
	end

	local files = {}
	for _, g in ipairs(project_groups()) do
		local roots = {}
		for _, r in ipairs(g.roots) do
			local rn = node(r)
			if rn then
				roots[#roots + 1] = rn
			end
		end
		files[#files + 1] = { path = g.path, roots = roots }
	end
	return { files = files }
end

return M
