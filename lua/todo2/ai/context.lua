-- lua/todo2/ai/context.lua
-- 上下文收集器：整合所有信息，形成 AI 所需的最终上下文

local M = {}

local core = require("todo2.store.link.core")
local code_block = require("todo2.code_block")
local task_graph = require("todo2.core.task_graph")

---------------------------------------------------------------------
-- 类型定义
---------------------------------------------------------------------

--- @class CodeBlockInfo
--- @field type string
--- @field name string|nil
--- @field signature string|nil
--- @field start_line integer
--- @field end_line integer
--- @field lang string|nil

--- @class BoundaryInfo
--- @field start_line integer
--- @field end_line integer
--- @field confidence number
--- @field block_type string
--- @field block_name string|nil
--- @field signature string|nil

--- @class TagAnalysis
--- @field type string
--- @field primary string|nil
--- @field all string[]

--- @class AIContext
--- @field code string|nil
--- @field start_line integer
--- @field end_line integer
--- @field block CodeBlockInfo|nil
--- @field lang string|nil
--- @field path string
--- @field signature_hash string|nil
--- @field task table|nil
--- @field parent table|nil
--- @field children table[]
--- @field siblings table[]
--- @field related table[]
--- @field semantic table[]
--- @field meta table
--- @field tag_analysis TagAnalysis
--- @field boundary BoundaryInfo
--- @field _raw table|nil

---------------------------------------------------------------------
-- 内部函数
---------------------------------------------------------------------

local function analyze_tags(task)
	if not task or not task.core or not task.core.tags then
		return { type = "unknown", primary = nil, all = {} }
	end

	local type_map = {
		FIX = "bug_fix",
		BUG = "bug_fix",
		REFACTOR = "refactor",
		OPTIMIZE = "performance",
		FEATURE = "feature",
		TODO = "feature",
		TEST = "testing",
		DOC = "documentation",
	}

	local primary = nil
	local task_type = "unknown"

	for _, tag in ipairs(task.core.tags) do
		if type_map[tag] then
			task_type = type_map[tag]
			primary = tag
			break
		end
	end

	return {
		type = task_type,
		primary = primary,
		all = task.core.tags,
	}
end

local function detect_boundary(task_id, file_path, line, context_blocks)
	_ = task_id
	_ = file_path

	local boundaries = {
		start_line = line,
		end_line = line,
		confidence = 1.0,
		block_type = "line",
		block_name = nil,
		signature = nil,
	}

	if context_blocks and context_blocks.block then
		local block = context_blocks.block
		boundaries.start_line = block.start_line
		boundaries.end_line = block.end_line
		boundaries.block_type = block.type or "block"
		boundaries.block_name = block.name
		boundaries.signature = block.signature
		boundaries.confidence = 0.9
	end

	return boundaries
end

local function get_language_from_storage(task)
	if task and task.locations and task.locations.code and task.locations.code.context then
		local block_info = task.locations.code.context.code_block_info
		if block_info and block_info.language then
			return block_info.language
		end
	end
	return "unknown"
end

local function get_signature_hash_from_storage(task)
	if task and task.locations and task.locations.code and task.locations.code.context then
		local block_info = task.locations.code.context.code_block_info
		if block_info and block_info.signature_hash then
			return block_info.signature_hash
		end
	end
	return nil
end

local function validate_language(stored_lang, file_path, task_id)
	if not stored_lang or stored_lang == "unknown" then
		return
	end

	local ok, detected = pcall(vim.filetype.match, { filename = file_path })
	if not ok or not detected then
		return
	end

	if stored_lang ~= detected then
		vim.notify(
			string.format(
				"[todo2] 语言不匹配警告\n任务: %s\n文件: %s\n存储语言: %s\n实际语言: %s",
				task_id,
				vim.fn.fnamemodify(file_path, ":t"),
				stored_lang,
				detected
			),
			vim.log.levels.WARN
		)
	end
end

---------------------------------------------------------------------
-- 主接口
---------------------------------------------------------------------

function M.collect_enhanced(code_link, task_id, opts)
	opts = opts or {}

	if not code_link or not code_link.path or not code_link.line then
		return nil
	end

	local task = core.get_task(task_id)
	if not task then
		return nil
	end

	local lang = get_language_from_storage(task)
	local signature_hash = get_signature_hash_from_storage(task)

	validate_language(lang, code_link.path, task_id)

	local bufnr = vim.fn.bufadd(code_link.path)
	vim.fn.bufload(bufnr)

	local block = code_block.get_block_at_line(bufnr, code_link.line)
	print("🪚 block: " .. tostring(block))
	local code = nil
	local start_line = code_link.line
	local end_line = code_link.line

	if block then
		start_line = block.start_line
		end_line = block.end_line

		if opts.include_code ~= false then
			local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
			code = table.concat(lines, "\n")
		end
	end

	local todo_path = task.locations.todo and task.locations.todo.path
	local graph_ctx = {
		task = nil,
		parent = nil,
		children = {},
		siblings = {},
		related = {},
		semantic = {},
		meta = {},
	}

	if todo_path then
		graph_ctx = task_graph.get_ai_context(task_id, todo_path, {
			max_children = opts.max_children or 5,
			max_semantic = opts.max_semantic or 3,
			strip_context = true,
		}) or graph_ctx
	end

	local tag_analysis = analyze_tags(task)

	local boundary = detect_boundary(task_id, code_link.path, code_link.line, {
		block = block,
	})

	local ctx = {
		code = code,
		start_line = start_line,
		end_line = end_line,
		block = block,
		lang = lang,
		path = code_link.path,
		signature_hash = signature_hash,

		task = graph_ctx.task,
		parent = graph_ctx.parent,
		children = graph_ctx.children or {},
		siblings = graph_ctx.siblings or {},
		related = graph_ctx.related or {},
		semantic = graph_ctx.semantic or {},
		meta = graph_ctx.meta or {},

		tag_analysis = tag_analysis,
		boundary = boundary,

		_raw = {
			task = task,
			graph = graph_ctx,
			block = block,
		},
	}

	if ctx.task and not ctx.task.task_type then
		ctx.task.task_type = tag_analysis.type
		ctx.task.primary_tag = tag_analysis.primary
	end

	if ctx.task and not ctx.task.language then
		ctx.task.language = lang
	end

	if ctx.task and not ctx.task.signature_hash then
		ctx.task.signature_hash = signature_hash
	end

	return ctx
end

function M.collect(code_link)
	if not code_link or not code_link.path or not code_link.line then
		return nil
	end

	local bufnr = vim.fn.bufadd(code_link.path)
	vim.fn.bufload(bufnr)

	local block = code_block.get_block_at_line(bufnr, code_link.line)
	print("🪚 block: " .. tostring(block))
	if not block then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, block.start_line - 1, block.end_line, false)
	local code = table.concat(lines, "\n")

	return {
		start_line = block.start_line,
		end_line = block.end_line,
		code = code,
		block = block,
		lang = vim.bo[bufnr].filetype,
		path = code_link.path,
	}
end

-- require("todo.ai.context").debug_print()
function M.debug_print(ctx)
	if not ctx then
		print("上下文为空")
		return
	end

	print("=== 上下文摘要 ===")
	print(string.format("文件: %s", ctx.path or "unknown"))
	print(string.format("代码范围: %d-%d", ctx.start_line or 0, ctx.end_line or 0))
	print(string.format("语言: %s", ctx.lang or "unknown"))
	if ctx.signature_hash then
		print(string.format("签名哈希: %s", ctx.signature_hash))
	end
	print("")

	if ctx.task then
		print("--- 任务 ---")
		print(string.format("内容: %s", ctx.task.content or ""))
		print(string.format("类型: %s", ctx.task.task_type or "unknown"))
		print(string.format("标签: %s", table.concat(ctx.task.tags or {}, ", ")))
		if ctx.task.language then
			print(string.format("语言: %s", ctx.task.language))
		end
		if ctx.task.signature_hash then
			print(string.format("签名哈希: %s", ctx.task.signature_hash))
		end
		print("")
	end

	if ctx.parent then
		print("--- 父任务 ---")
		print(string.format("内容: %s", ctx.parent.content or ""))
		print("")
	end

	if ctx.children and #ctx.children > 0 then
		print("--- 子任务 ---")
		for i, child in ipairs(ctx.children) do
			print(string.format("%d. %s", i, child.content or ""))
		end
		if ctx.meta and ctx.meta.children_truncated then
			print(string.format("... 还有 %d 个子任务", ctx.meta.children_truncated_count or 0))
		end
		print("")
	end

	if ctx.semantic and #ctx.semantic > 0 then
		print("--- 语义相似任务 ---")
		for i, sem in ipairs(ctx.semantic) do
			local sim = sem.similarity and string.format(" (%.0f%%)", sem.similarity * 100) or ""
			print(string.format("%d. %s%s", i, sem.content or "", sim))
		end
		print("")
	end

	if ctx.boundary then
		print("--- 修改边界 ---")
		print(string.format("范围: %d-%d", ctx.boundary.start_line or 0, ctx.boundary.end_line or 0))
		print(string.format("类型: %s", ctx.boundary.block_type or "unknown"))
		if ctx.boundary.signature then
			print(string.format("签名: %s", ctx.boundary.signature))
		end
		print("")
	end

	if ctx.meta then
		print("--- 元信息 ---")
		print(string.format("总子任务: %d", ctx.meta.total_children or 0))
		print(string.format("进度: %d%%", ctx.meta.children_progress or 0))
		print(string.format("深度: %d", ctx.meta.depth or 0))
		print("")
	end
end

return M
