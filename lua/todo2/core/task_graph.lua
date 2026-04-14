-- lua/todo2/core/task_graph.lua
-- 基于存储的任务图谱系统（文件树 + 数据树 + 语义图 + 上下文图）
-- 重构版：移除对 scheduler 解析缓存的依赖

local M = {}

local core = require("todo2.store.link.core")
local relation = require("todo2.store.link.relation")
local index = require("todo2.store.index")

local ok_embedding, embedding = pcall(require, "todo2.core.embedding")

---------------------------------------------------------------------
-- 类型定义
---------------------------------------------------------------------

--- @class TaskNode
--- @field key string
--- @field id string|nil
--- @field type string
--- @field content string
--- @field path string|nil
--- @field line integer|nil
--- @field core table|nil
--- @field ctx table|nil
--- @field relations table|nil

--- @class GraphEdge
--- @field from string
--- @field to string
--- @field type string
--- @field similarity number|nil

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

local function make_key(id, path, line)
	if id then
		return id
	end
	return string.format("__noid_%s:%d", path or "unknown", line or 0)
end

local function tokenize(text)
	local words = {}
	for w in text:lower():gmatch("[%w_]+") do
		if #w > 1 then
			words[w] = true
		end
	end
	return words
end

local function keyword_similarity(a, b)
	local ta = tokenize(a)
	local tb = tokenize(b)
	local inter = 0
	local total = 0
	for w in pairs(ta) do
		total = total + 1
		if tb[w] then
			inter = inter + 1
		end
	end
	return total == 0 and 0 or inter / total
end

local function semantic_similarity(a, b)
	local text_a = a.content or ""
	local text_b = b.content or ""
	if text_a == "" or text_b == "" then
		return 0
	end

	if ok_embedding and embedding.is_available and embedding.is_available() then
		local va = embedding.get(text_a)
		local vb = embedding.get(text_b)
		if va and vb then
			local ok_sim, sim = pcall(embedding.similarity, va, vb)
			if ok_sim and type(sim) == "number" then
				return sim
			end
		end
	end

	return keyword_similarity(text_a, text_b)
end

local function infer_task_type(tags)
	if not tags or #tags == 0 then
		return "unknown"
	end

	local type_map = {
		FIX = "bug_fix",
		BUG = "bug_fix",
		HOTFIX = "bug_fix",
		REFACTOR = "refactor",
		OPTIMIZE = "performance",
		CLEANUP = "cleanup",
		FEATURE = "feature",
		TODO = "feature",
		ENHANCE = "enhancement",
		TEST = "testing",
		SPEC = "testing",
		DOC = "documentation",
		COMMENT = "documentation",
	}

	for _, tag in ipairs(tags) do
		local mapped = type_map[tag]
		if mapped then
			return mapped
		end
	end

	return "unknown"
end

local function generate_code_summary(ctx)
	if not ctx or not ctx.context or not ctx.context.code_block_info then
		return nil
	end

	local block = ctx.context.code_block_info
	local file_name = vim.fn.fnamemodify(ctx.path, ":t")

	return {
		type = block.type,
		name = block.name,
		signature = block.signature,
		signature_hash = block.signature_hash,
		language = block.language,
		location = string.format("%s:%d", file_name, ctx.line),
		line_range = string.format("%d-%d", block.start_line, block.end_line),
	}
end

---------------------------------------------------------------------
-- 从存储获取文件中的任务
---------------------------------------------------------------------

---获取文件中的所有任务（基于存储和索引）
---@param path string
---@return table[]
local function get_tasks_in_file(path)
	local tasks = {}

	-- 从索引获取 TODO 任务
	local todo_tasks = index.find_todo_links_by_file(path)
	for _, task in ipairs(todo_tasks) do
		table.insert(tasks, {
			id = task.id,
			path = path,
			line_num = task.locations.todo.line,
			content = task.core.content,
			children = {},
			parent = nil,
		})
	end

	-- 从索引获取 CODE 任务
	local code_tasks = index.find_code_links_by_file(path)
	for _, task in ipairs(code_tasks) do
		table.insert(tasks, {
			id = task.id,
			path = path,
			line_num = task.locations.code.line,
			content = task.core.content,
			children = {},
			parent = nil,
		})
	end

	-- 按行号排序
	table.sort(tasks, function(a, b)
		return (a.line_num or 0) < (b.line_num or 0)
	end)

	return tasks
end

---------------------------------------------------------------------
-- 构建节点和边
---------------------------------------------------------------------

local function build_nodes(file_tasks)
	local nodes = {}

	for _, t in ipairs(file_tasks or {}) do
		local key = make_key(t.id, t.path, t.line_num)

		local full_task = t.id and core.get_task(t.id) or nil

		nodes[key] = {
			key = key,
			id = t.id,
			type = t.id and "data" or "file",
			content = t.content or "",
			path = t.path,
			line = t.line_num,
			core = full_task and full_task.core or nil,
			ctx = t.id and core.get_code_location(t.id) or nil,
			relations = full_task and full_task.relations or nil,
			children = t.children,
			parent = t.parent,
		}
	end

	return nodes
end

local function add_edge(edges, from, to, type_, similarity)
	if not from or not to then
		return
	end
	edges[from] = edges[from] or {}
	local edge = { from = from, to = to, type = type_ }
	if similarity then
		edge.similarity = similarity
	end
	table.insert(edges[from], edge)
end

local function build_edges(nodes)
	local edges = {}

	-- 数据结构（基于 relation 模块）
	for key, node in pairs(nodes) do
		if node.id then
			local parent_id = relation.get_parent_id(node.id)
			if parent_id and nodes[parent_id] then
				add_edge(edges, key, parent_id, "parent")
				add_edge(edges, parent_id, key, "child")
			end

			local children_ids = relation.get_child_ids(node.id)
			for _, child_id in ipairs(children_ids) do
				if nodes[child_id] then
					add_edge(edges, key, child_id, "child")
					add_edge(edges, child_id, key, "parent")
				end
			end

			-- 兄弟关系
			if parent_id then
				local siblings = relation.get_child_ids(parent_id)
				for _, sib_id in ipairs(siblings) do
					if sib_id ~= node.id and nodes[sib_id] then
						add_edge(edges, key, sib_id, "sibling")
					end
				end
			end
		end
	end

	-- 相关任务（如果有）
	for key, node in pairs(nodes) do
		if node.id and node.core and node.core.related_ids then
			for _, rid in ipairs(node.core.related_ids) do
				if nodes[rid] then
					add_edge(edges, key, rid, "related")
					add_edge(edges, rid, key, "related")
				end
			end
		end
	end

	-- 语义相似度
	local id_nodes = {}
	for key, node in pairs(nodes) do
		if node.id then
			table.insert(id_nodes, { key = key, node = node })
		end
	end

	for i = 1, #id_nodes do
		for j = i + 1, #id_nodes do
			local a = id_nodes[i]
			local b = id_nodes[j]
			local sim = semantic_similarity(a.node, b.node)
			if sim >= 0.4 then
				add_edge(edges, a.key, b.key, "semantic", sim)
				add_edge(edges, b.key, a.key, "semantic", sim)
			end
		end
	end

	return edges
end

---------------------------------------------------------------------
-- 构建文件树（基于缩进，需要读取文件）
---------------------------------------------------------------------

local function build_file_tree_from_buffer(bufnr, tasks)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return tasks -- 无法构建树，返回扁平列表
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local task_by_line = {}

	for _, task in ipairs(tasks) do
		if task.line_num then
			task_by_line[task.line_num] = task
		end
	end

	local roots = {}
	local stack = {} -- { level, task }

	for i, line in ipairs(lines) do
		local task = task_by_line[i]
		if task then
			local indent = line:match("^(%s*)")
			local level = #indent

			while #stack > 0 and stack[#stack].level >= level do
				table.remove(stack)
			end

			if #stack > 0 then
				local parent = stack[#stack].task
				parent.children = parent.children or {}
				table.insert(parent.children, task)
				task.parent = parent
			else
				table.insert(roots, task)
			end

			table.insert(stack, { level = level, task = task })
		end
	end

	return roots
end

---------------------------------------------------------------------
-- 公开 API
---------------------------------------------------------------------

---获取文件的任务图谱（基于存储）
---@param path string 文件路径
---@param bufnr number|nil 缓冲区号（可选，用于构建文件树）
---@return table
function M.get_graph_for_path(path, bufnr)
	if not path or path == "" then
		return { nodes = {}, edges = {}, roots = {} }
	end

	-- 从存储获取任务
	local file_tasks = get_tasks_in_file(path)

	-- 构建文件树（如果提供了 bufnr）
	local roots = {}
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		roots = build_file_tree_from_buffer(bufnr, file_tasks)
	else
		roots = file_tasks
	end

	-- 构建节点和边
	local nodes = build_nodes(file_tasks)
	local edges = build_edges(nodes)

	return {
		nodes = nodes,
		edges = edges,
		roots = roots,
	}
end

---获取任务上下文（原始版本）
---@param task_id string
---@param path string
---@return table
function M.get_task_context(task_id, path)
	local graph = M.get_graph_for_path(path)
	local nodes = graph.nodes
	local edges = graph.edges

	local task = nodes[task_id]
	if not task then
		return {}
	end

	local ctx = {
		task = task,
		parent = nil,
		children = {},
		siblings = {},
		related = {},
		semantic = {},
	}

	for _, e in ipairs(edges[task_id] or {}) do
		local t = nodes[e.to]
		if t then
			if e.type == "parent" then
				ctx.parent = t
			elseif e.type == "child" then
				table.insert(ctx.children, t)
			elseif e.type == "sibling" then
				table.insert(ctx.siblings, t)
			elseif e.type == "related" then
				table.insert(ctx.related, t)
			elseif e.type == "semantic" then
				table.insert(ctx.semantic, {
					node = t,
					similarity = e.similarity,
				})
			end
		end
	end

	return ctx
end

---AI 友好版：获取任务上下文（增强版）
---@param task_id string
---@param path string
---@param opts table
---@return table
function M.get_ai_context(task_id, path, opts)
	opts = opts or {}
	local max_children = opts.max_children or 5
	local max_semantic = opts.max_semantic or 3
	local include_metadata = opts.include_metadata ~= false

	local ctx = M.get_task_context(task_id, path)
	if not ctx.task then
		return ctx
	end

	local function enhance_node(node, similarity)
		if not node or not node.id then
			return node
		end

		local enhanced = vim.deepcopy(node)
		local task = core.get_task(node.id)

		if task then
			enhanced.tags = task.core.tags
			enhanced.primary_tag = task.core.tags and task.core.tags[1]
			enhanced.task_type = infer_task_type(task.core.tags)
			enhanced.status = task.core.status

			if task.locations and task.locations.code and task.locations.code.context then
				local block_info = task.locations.code.context.code_block_info
				if block_info then
					enhanced.language = block_info.language
					enhanced.signature_hash = block_info.signature_hash
				end
			end

			if enhanced.ctx then
				enhanced.code_summary = generate_code_summary(enhanced.ctx)
				if opts.strip_context then
					enhanced.ctx = nil
				end
			end
		end

		if similarity then
			enhanced.similarity = similarity
		end

		if enhanced.path then
			enhanced.file_name = vim.fn.fnamemodify(enhanced.path, ":t")
		end

		return enhanced
	end

	ctx.task = enhance_node(ctx.task)

	if ctx.parent then
		ctx.parent = enhance_node(ctx.parent)
	end

	local enhanced_children = {}
	local children_count = #ctx.children
	for i = 1, math.min(children_count, max_children) do
		table.insert(enhanced_children, enhance_node(ctx.children[i]))
	end
	ctx.children = enhanced_children
	if children_count > max_children then
		ctx.children_truncated = true
		ctx.children_truncated_count = children_count - max_children
	end

	local enhanced_siblings = {}
	for _, sibling in ipairs(ctx.siblings) do
		table.insert(enhanced_siblings, enhance_node(sibling))
	end
	ctx.siblings = enhanced_siblings

	local enhanced_related = {}
	for _, related in ipairs(ctx.related) do
		table.insert(enhanced_related, enhance_node(related))
	end
	ctx.related = enhanced_related

	local enhanced_semantic = {}
	local semantic_count = #ctx.semantic
	local sorted_semantic = {}
	for _, item in ipairs(ctx.semantic) do
		table.insert(sorted_semantic, item)
	end
	table.sort(sorted_semantic, function(a, b)
		return (a.similarity or 0) > (b.similarity or 0)
	end)

	for i = 1, math.min(semantic_count, max_semantic) do
		local item = sorted_semantic[i]
		table.insert(enhanced_semantic, enhance_node(item.node, item.similarity))
	end
	ctx.semantic = enhanced_semantic
	if semantic_count > max_semantic then
		ctx.semantic_truncated = true
		ctx.semantic_truncated_count = semantic_count - max_semantic
	end

	if include_metadata then
		local total_children = children_count
		local completed_children = 0
		for _, child in ipairs(ctx.children) do
			if child.status == "completed" then
				completed_children = completed_children + 1
			end
		end

		ctx.meta = {
			total_children = total_children,
			total_semantic = semantic_count,
			total_related = #ctx.related,
			total_siblings = #ctx.siblings,
			has_parent = ctx.parent ~= nil,
			is_root = ctx.parent == nil,
			depth = ctx.task.relations and ctx.task.relations.level or 0,
			completed_children = completed_children,
			children_progress = total_children > 0 and math.floor(completed_children / total_children * 100) or 0,
		}

		if ctx.parent and ctx.parent.id then
			local siblings_with_parent = relation.get_child_ids(ctx.parent.id)
			for idx, sid in ipairs(siblings_with_parent) do
				if sid == task_id then
					ctx.meta.position_in_siblings = idx
					ctx.meta.total_siblings = #siblings_with_parent
					break
				end
			end
		end
	end

	return ctx
end

return M
