-- lua/todo2/core/task_graph.lua
-- 完全重构版任务图谱系统（文件树 + 数据树 + 语义图 + 上下文图）
-- 增强版：支持 AI 友好的上下文输出

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
--- @field similarity number|nil 语义相似度分数（仅 semantic 边）

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
-- 工具：任务类型推断
---------------------------------------------------------------------

--- 根据标签推断任务类型（AI 友好）
--- @param tags string[] 任务标签
--- @return string 任务类型
local function infer_task_type(tags)
	if not tags or #tags == 0 then
		return "unknown"
	end

	local type_map = {
		-- 修复类
		FIX = "bug_fix",
		BUG = "bug_fix",
		HOTFIX = "bug_fix",
		-- 重构类
		REFACTOR = "refactor",
		OPTIMIZE = "performance",
		CLEANUP = "cleanup",
		-- 功能类
		FEATURE = "feature",
		TODO = "feature",
		ENHANCE = "enhancement",
		-- 测试类
		TEST = "testing",
		SPEC = "testing",
		-- 文档类
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

---------------------------------------------------------------------
-- 工具：代码摘要生成
---------------------------------------------------------------------

--- 生成代码摘要（减少 token 消耗）
--- @param ctx table 代码上下文
--- @return table|nil
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
		language = block.language, -- ✅ 添加语言字段
		location = string.format("%s:%d", file_name, ctx.line),
		line_range = string.format("%d-%d", block.start_line, block.end_line),
	}
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
-- 构建边（统一结构，支持相似度分数）
---------------------------------------------------------------------

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
	-- 4. 语义相似（semantic）- 带相似度分数
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
				-- 双向边，都带上相似度分数
				add_edge(edges, a.key, b.key, "semantic", sim)
				add_edge(edges, b.key, a.key, "semantic", sim)
			end
		end
	end

	------------------------------------------------------------------
	-- 5. 上下文图（context）- 预留
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
-- 获取任务上下文（原始版本，保持兼容）
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
				-- 语义任务保存相似度
				table.insert(ctx.semantic, {
					node = t,
					similarity = e.similarity,
				})
			end
		end
	end

	return ctx
end

---------------------------------------------------------------------
-- AI 友好版：获取任务上下文（增强版）
---------------------------------------------------------------------

--- 获取 AI 优化后的任务上下文
--- @param task_id string 任务ID
--- @param path string TODO文件路径
--- @param opts table 选项
---   - max_children: number 最大子任务数（默认5）
---   - max_semantic: number 最大语义相似任务数（默认3）
---   - include_metadata: boolean 是否包含元信息（默认true）
---   - strip_context: boolean 是否移除完整 ctx（默认false）
--- @return table 增强后的上下文
function M.get_ai_context(task_id, path, opts)
	opts = opts or {}
	local max_children = opts.max_children or 5
	local max_semantic = opts.max_semantic or 3
	local include_metadata = opts.include_metadata ~= false

	-- 获取原始上下文
	local ctx = M.get_task_context(task_id, path)
	if not ctx.task then
		return ctx
	end

	-----------------------------------------------------------------
	-- 增强单个节点
	-----------------------------------------------------------------
	local function enhance_node(node, similarity)
		if not node or not node.id then
			return node
		end

		local enhanced = vim.deepcopy(node)

		-- 获取完整任务数据
		local task = core.get_task(node.id)
		if task then
			-- 添加标签和类型
			enhanced.tags = task.core.tags
			enhanced.primary_tag = task.core.tags and task.core.tags[1]
			enhanced.task_type = infer_task_type(task.core.tags)
			enhanced.status = task.core.status

			-- ✅ 添加语言字段（直接从存储获取）
			if task.locations and task.locations.code and task.locations.code.context then
				local block_info = task.locations.code.context.code_block_info
				if block_info and block_info.language then
					enhanced.language = block_info.language
				end
			end

			-- 添加代码摘要
			if enhanced.ctx then
				enhanced.code_summary = generate_code_summary(enhanced.ctx)
				if opts.strip_context then
					enhanced.ctx = nil
				end
			end
		end

		-- 添加相似度分数（如果是语义任务）
		if similarity then
			enhanced.similarity = similarity
		end

		-- 简化路径（只保留文件名）
		if enhanced.path then
			enhanced.file_name = vim.fn.fnamemodify(enhanced.path, ":t")
		end

		return enhanced
	end

	-----------------------------------------------------------------
	-- 应用增强
	-----------------------------------------------------------------

	-- 增强当前任务
	ctx.task = enhance_node(ctx.task)

	-- 增强父任务
	if ctx.parent then
		ctx.parent = enhance_node(ctx.parent)
	end

	-- 增强子任务（限制数量）
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

	-- 增强兄弟任务
	local enhanced_siblings = {}
	for _, sibling in ipairs(ctx.siblings) do
		table.insert(enhanced_siblings, enhance_node(sibling))
	end
	ctx.siblings = enhanced_siblings

	-- 增强相关任务
	local enhanced_related = {}
	for _, related in ipairs(ctx.related) do
		table.insert(enhanced_related, enhance_node(related))
	end
	ctx.related = enhanced_related

	-- 增强语义相似任务（带分数，限制数量）
	local enhanced_semantic = {}
	local semantic_count = #ctx.semantic
	-- 按相似度排序（高分优先）
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

	-----------------------------------------------------------------
	-- 添加元信息
	-----------------------------------------------------------------
	if include_metadata then
		-- 统计信息
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

		-- 如果是子任务，添加在组中的位置信息
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
