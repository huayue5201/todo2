-- lua/todo2/ai/context.lua
-- 上下文收集器：整合所有信息，形成 AI 所需的最终上下文
-- @module todo2.ai.context

local M = {}

local core = require("todo2.store.link.core")
local code_block = require("todo2.code_block")
local task_graph = require("todo2.core.task_graph")

---------------------------------------------------------------------
-- 类型定义（解决类型警告）
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
-- 内部模块
---------------------------------------------------------------------

--- 标签分析器
--- @param task table 任务对象
--- @return TagAnalysis
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

--- 边界检测器
--- @param task_id string 任务ID
--- @param file_path string 文件路径
--- @param line integer 行号
--- @param context_blocks table|nil 代码块上下文
--- @return BoundaryInfo
local function detect_boundary(task_id, file_path, line, context_blocks)
	-- 避免 unused 警告
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

	-- 使用 code_block 获取精确边界
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

--- 从存储获取语言信息（数据为唯一真相）
--- @param task table 任务对象
--- @return string
local function get_language_from_storage(task)
	if task and task.locations and task.locations.code and task.locations.code.context then
		local block_info = task.locations.code.context.code_block_info
		if block_info and block_info.language then
			return block_info.language
		end
	end
	return "unknown"
end

--- 验证存储的语言与文件实际类型是否一致
--- @param stored_lang string 存储的语言
--- @param file_path string 文件路径
--- @param task_id string 任务ID
local function validate_language(stored_lang, file_path, task_id)
	if not stored_lang or stored_lang == "unknown" then
		return
	end

	-- 使用 Neovim API 检测实际文件类型
	local ok, detected = pcall(vim.filetype.match, { filename = file_path })
	if not ok or not detected then
		return
	end

	-- 直接对比
	if stored_lang ~= detected then
		vim.notify(
			string.format(
				"[todo2] 语言不匹配警告\n任务: %s\n文件: %s\n存储语言: %s\n实际语言: %s\n这可能影响 AI 生成的注释格式",
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
-- 主接口：收集完整上下文
---------------------------------------------------------------------

--- 收集增强上下文（整合所有信息）
--- @param code_link table 代码链接 { path, line, context? }
--- @param task_id string 任务ID
--- @param opts table|nil 选项
---   - max_children: number 最大子任务数（默认5）
---   - max_semantic: number 最大语义相似任务数（默认3）
---   - include_code: boolean 是否包含代码内容（默认true）
---   - context_lines: number 上下文行数（默认0，0表示整个块）
--- @return AIContext|nil 完整的上下文对象
function M.collect_enhanced(code_link, task_id, opts)
	opts = opts or {}

	if not code_link or not code_link.path or not code_link.line then
		return nil
	end

	-- ============================================================
	-- 1. 获取任务对象
	-- ============================================================
	local task = core.get_task(task_id)
	if not task then
		return nil
	end

	-- ============================================================
	-- 2. 从存储获取语言信息（数据为唯一真相）
	-- ============================================================
	local lang = get_language_from_storage(task)

	-- ============================================================
	-- 3. 验证语言（仅警告，不影响结果）
	-- ============================================================
	validate_language(lang, code_link.path, task_id)

	-- ============================================================
	-- 4. 收集代码上下文（仅用于获取代码内容）
	-- ============================================================
	local bufnr = vim.fn.bufadd(code_link.path)
	vim.fn.bufload(bufnr)

	local block = code_block.get_block_at_line(bufnr, code_link.line)
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

	-- ============================================================
	-- 5. 获取任务图谱上下文
	-- ============================================================
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

	-- ============================================================
	-- 6. 标签分析
	-- ============================================================
	local tag_analysis = analyze_tags(task)

	-- ============================================================
	-- 7. 边界检测
	-- ============================================================
	local boundary = detect_boundary(task_id, code_link.path, code_link.line, {
		block = block,
	})

	-- ============================================================
	-- 8. 构建最终上下文
	-- ============================================================
	--- @type AIContext
	local ctx = {
		-- 代码上下文
		code = code,
		start_line = start_line,
		end_line = end_line,
		block = block,
		lang = lang, -- 从存储获取
		path = code_link.path,

		-- 任务上下文
		task = graph_ctx.task,
		parent = graph_ctx.parent,
		children = graph_ctx.children or {},
		siblings = graph_ctx.siblings or {},
		related = graph_ctx.related or {},
		semantic = graph_ctx.semantic or {},
		meta = graph_ctx.meta or {},

		-- 分析结果
		tag_analysis = tag_analysis,
		boundary = boundary,

		-- 原始数据（调试用）
		_raw = {
			task = task,
			graph = graph_ctx,
			block = block,
		},
	}

	-- 添加任务类型到 task 节点（如果还没有）
	if ctx.task and not ctx.task.task_type then
		ctx.task.task_type = tag_analysis.type
		ctx.task.primary_tag = tag_analysis.primary
	end

	-- 如果 task 节点还没有语言信息，从存储补充
	if ctx.task and not ctx.task.language then
		ctx.task.language = lang
	end

	return ctx
end

---------------------------------------------------------------------
-- 简化版：只收集代码上下文（保持兼容）
---------------------------------------------------------------------

--- 收集代码上下文（原有接口）
--- @param code_link table 代码链接
--- @return table|nil
function M.collect(code_link)
	if not code_link or not code_link.path or not code_link.line then
		return nil
	end

	local bufnr = vim.fn.bufadd(code_link.path)
	vim.fn.bufload(bufnr)

	local block = code_block.get_block_at_line(bufnr, code_link.line)
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

---------------------------------------------------------------------
-- 调试：打印上下文摘要
---------------------------------------------------------------------

--- 打印上下文摘要（用于调试）
--- @param ctx AIContext
function M.debug_print(ctx)
	if not ctx then
		print("上下文为空")
		return
	end

	print("=== 上下文摘要 ===")
	print(string.format("文件: %s", ctx.path or "unknown"))
	print(string.format("代码范围: %d-%d", ctx.start_line or 0, ctx.end_line or 0))
	print(string.format("语言: %s", ctx.lang or "unknown"))
	print("")

	if ctx.task then
		print("--- 任务 ---")
		print(string.format("内容: %s", ctx.task.content or ""))
		print(string.format("类型: %s", ctx.task.task_type or "unknown"))
		print(string.format("标签: %s", table.concat(ctx.task.tags or {}, ", ")))
		if ctx.task.language then
			print(string.format("语言: %s", ctx.task.language))
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
