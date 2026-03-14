-- lua/todo2/core/task_graph.lua
-- 任务图谱（semantic task graph，embedding 增强版）

local M = {}

local scheduler = require("todo2.render.scheduler")
local link_mod = require("todo2.store.link")

local ok_embedding, embedding = pcall(require, "todo2.core.embedding")

---------------------------------------------------------------------
-- 简单分词相似度（作为 embedding 的 fallback）
---------------------------------------------------------------------
local function tokenize(text)
	if not text or text == "" then
		return {}
	end
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

	if total == 0 then
		return 0
	end

	return inter / total
end

---------------------------------------------------------------------
-- 统一语义相似度接口（优先使用 embedding）
---------------------------------------------------------------------
local function semantic_similarity(task_a, task_b)
	local text_a = task_a.content or ""
	local text_b = task_b.content or ""
	if text_a == "" or text_b == "" then
		return 0
	end

	-- 优先使用 embedding
	if ok_embedding and embedding and embedding.is_available and embedding.is_available() then
		local va = embedding.get(text_a)
		local vb = embedding.get(text_b)
		if va and vb then
			local ok_sim, sim = pcall(embedding.similarity, va, vb)
			if ok_sim and type(sim) == "number" then
				return sim
			end
		end
	end

	-- fallback：关键词相似度
	return keyword_similarity(text_a, text_b)
end

---------------------------------------------------------------------
-- 构建图谱节点
---------------------------------------------------------------------
local function build_nodes(tasks)
	local nodes = {}
	for _, t in ipairs(tasks) do
		local key = t.id or ("__noid_" .. (t.line_num or 0))
		nodes[key] = t
	end
	return nodes
end

---------------------------------------------------------------------
-- 构建图谱边（父子 / 兄弟 / related / 语义）
---------------------------------------------------------------------
local function build_edges(nodes)
	local edges = {}

	local function add_edge(a, b, type_)
		if not a or not b then
			return
		end
		if not nodes[a] or not nodes[b] then
			return
		end
		edges[a] = edges[a] or {}
		table.insert(edges[a], { to = b, type = type_ })
	end

	-- 父子 + 兄弟
	for id, task in pairs(nodes) do
		if task.parent and task.parent.id then
			add_edge(task.id, task.parent.id, "parent")
			add_edge(task.parent.id, task.id, "child")
		end

		if task.parent and task.parent.children then
			for _, sibling in ipairs(task.parent.children) do
				if sibling.id and sibling.id ~= task.id then
					add_edge(task.id, sibling.id, "sibling")
				end
			end
		end
	end

	-- related（来自 store/link）
	for id, task in pairs(nodes) do
		if task.id then
			local link = link_mod.get_todo(task.id) or link_mod.get_code(task.id)
			if link and link.related_ids then
				for _, rid in ipairs(link.related_ids) do
					if nodes[rid] then
						add_edge(task.id, rid, "related")
						add_edge(rid, task.id, "related")
					end
				end
			end
		end
	end

	-- 语义相似（embedding / 关键词）
	local ids = {}
	for id, _ in pairs(nodes) do
		table.insert(ids, id)
	end

	for i = 1, #ids do
		for j = i + 1, #ids do
			local a = nodes[ids[i]]
			local b = nodes[ids[j]]
			if a and b and a.id and b.id then
				local sim = semantic_similarity(a, b)
				-- 阈值你可以以后调，比如 0.4 / 0.5
				if sim >= 0.4 then
					add_edge(a.id, b.id, "semantic")
					add_edge(b.id, a.id, "semantic")
				end
			end
		end
	end

	return edges
end

---------------------------------------------------------------------
-- 对单文件构建图谱
---------------------------------------------------------------------
function M.get_graph_for_path(path)
	if not path or path == "" then
		return { nodes = {}, edges = {}, roots = {}, archive_trees = {} }
	end

	local tasks, roots, id_to_task, archive_trees = scheduler.get_parse_tree(path)

	local nodes = build_nodes(tasks or {})
	local edges = build_edges(nodes)

	return {
		nodes = nodes,
		edges = edges,
		roots = roots or {},
		archive_trees = archive_trees or {},
	}
end

---------------------------------------------------------------------
-- 获取任务链上下文（用于 prompt 注入）
---------------------------------------------------------------------
function M.get_task_context(task_id, path)
	if not task_id or not path or path == "" then
		return {}
	end

	local graph = M.get_graph_for_path(path)
	local nodes = graph.nodes or {}
	local edges = graph.edges or {}

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

	local es = edges[task_id] or {}
	for _, e in ipairs(es) do
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
				table.insert(ctx.semantic, t)
			end
		end
	end

	return ctx
end

return M
