-- lua/todo2/core/task_graph.lua
-- 完全重构版任务图谱系统（文件树 + 数据树 + 语义图 + 上下文图）

local M = {}

local scheduler = require("todo2.render.scheduler")
local core = require("todo2.store.link.core")
local relation = require("todo2.store.link.relation")

local ok_embedding, embedding = pcall(require, "todo2.core.embedding")

---------------------------------------------------------------------
-- 类型定义（严格 LuaDoc）
---------------------------------------------------------------------

--- @class TaskNode
--- @field key string 唯一 key（id 或 path:line）
--- @field id string|nil
--- @field type string 节点类型：todo/code/file/data/semantic
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

--- @class TaskGraph
--- @field nodes table<string, TaskNode>
--- @field edges table<string, GraphEdge[]>
--- @field roots TaskNode[]

---------------------------------------------------------------------
-- 工具：唯一 key
---------------------------------------------------------------------

local function make_key(id, path, line)
	if id then
		return id
	end
	return string.format("__noid_%s:%d", path, line)
end

---------------------------------------------------------------------
-- 工具：语义相似度
---------------------------------------------------------------------

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

---------------------------------------------------------------------
-- 构建节点（统一结构）
---------------------------------------------------------------------

local function build_nodes(file_tasks)
	local nodes = {}

	for _, t in ipairs(file_tasks or {}) do
		local key = make_key(t.id, t.path, t.line_num)

		nodes[key] = {
			key = key,
			id = t.id,
			type = t.id and "data" or "file",
			content = t.content or "",
			path = t.path,
			line = t.line_num,
			core = t.id and core.get_task(t.id).core or nil,
			ctx = t.id and (core.get_code_location(t.id)) or nil,
			relations = t.id and core.get_task(t.id).relations or nil,
			children = t.children,
			parent = t.parent,
		}
	end

	return nodes
end

---------------------------------------------------------------------
-- 构建边（统一结构）
---------------------------------------------------------------------

local function add_edge(edges, from, to, type_)
	if not from or not to then
		return
	end
	edges[from] = edges[from] or {}
	table.insert(edges[from], { from = from, to = to, type = type_ })
end

local function build_edges(nodes)
	local edges = {}

	------------------------------------------------------------------
	-- 1. 文件结构（file_child / file_parent / file_sibling）
	------------------------------------------------------------------
	for key, node in pairs(nodes) do
		if node.children then
			for _, child in ipairs(node.children) do
				local child_key = make_key(child.id, child.path, child.line_num)
				add_edge(edges, key, child_key, "file_child")
				add_edge(edges, child_key, key, "file_parent")
			end
		end

		if node.parent and node.parent.children then
			for _, sibling in ipairs(node.parent.children) do
				local sib_key = make_key(sibling.id, sibling.path, sibling.line_num)
				if sib_key ~= key then
					add_edge(edges, key, sib_key, "file_sibling")
				end
			end
		end
	end

	------------------------------------------------------------------
	-- 2. 数据结构（parent / child / sibling）
	------------------------------------------------------------------
	for key, node in pairs(nodes) do
		if node.id then
			local rel = node.relations
			if rel then
				-- parent
				if rel.parent_id then
					add_edge(edges, key, rel.parent_id, "parent")
					add_edge(edges, rel.parent_id, key, "child")
				end

				-- siblings
				if rel.parent_id then
					for _, sib_id in ipairs(relation.get_child_ids(rel.parent_id)) do
						if sib_id ~= node.id then
							add_edge(edges, key, sib_id, "sibling")
						end
					end
				end
			end
		end
	end

	------------------------------------------------------------------
	-- 3. 相关任务（related）
	------------------------------------------------------------------
	for key, node in pairs(nodes) do
		if node.id then
			local t = core.get_task(node.id)
			if t and t.core and t.core.related_ids then
				for _, rid in ipairs(t.core.related_ids) do
					if nodes[rid] then
						add_edge(edges, key, rid, "related")
						add_edge(edges, rid, key, "related")
					end
				end
			end
		end
	end

	------------------------------------------------------------------
	-- 4. 语义相似（semantic）
	------------------------------------------------------------------
	local id_nodes = {}
	for key, node in pairs(nodes) do
		if node.id then
			table.insert(id_nodes, node)
		end
	end

	for i = 1, #id_nodes do
		for j = i + 1, #id_nodes do
			local a = id_nodes[i]
			local b = id_nodes[j]
			local sim = semantic_similarity(a, b)
			if sim >= 0.4 then
				add_edge(edges, a.key, b.key, "semantic")
				add_edge(edges, b.key, a.key, "semantic")
			end
		end
	end

	------------------------------------------------------------------
	-- 5. 上下文图（context）
	------------------------------------------------------------------
	for key, node in pairs(nodes) do
		if node.ctx and node.ctx.context then
			for _, line in ipairs(node.ctx.context.lines or {}) do
				if line.normalized and #line.normalized > 0 then
					-- 这里可以扩展为 context → semantic 连接
				end
			end
		end
	end

	return edges
end

---------------------------------------------------------------------
-- 构建图谱（单文件）
---------------------------------------------------------------------

--- 构建单文件图谱
--- @param path string
--- @return TaskGraph
function M.get_graph_for_path(path)
	if not path or path == "" then
		return { nodes = {}, edges = {}, roots = {} }
	end

	-- scheduler 返回文件树（包含无 ID 节点）
	local file_tasks, roots = scheduler.get_parse_tree(path, false)

	-- 统一节点
	local nodes = build_nodes(file_tasks or {})

	-- 构建边
	local edges = build_edges(nodes)

	return {
		nodes = nodes,
		edges = edges,
		roots = roots or {},
	}
end

---------------------------------------------------------------------
-- 获取任务上下文（用于 AI prompt）
---------------------------------------------------------------------

--- 获取任务上下文（父 / 子 / 兄弟 / 相关 / 语义）
--- @param task_id string
--- @param path string
--- @return table
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
			if e.type == "parent" or e.type == "file_parent" then
				ctx.parent = t
			elseif e.type == "child" or e.type == "file_child" then
				table.insert(ctx.children, t)
			elseif e.type == "sibling" or e.type == "file_sibling" then
				table.insert(ctx.siblings, t)
			elseif e.type == "related" then
				table.insert(ctx.related, t)
			elseif e.type == "semantic" then
				table.insert(ctx.semantic, t)
			end
		end
	end

	return ctx
end

return M
