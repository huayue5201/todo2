-- lua/todo2/ai/prompt.lua
-- 工业级 Prompt：最小修改、完整替换、任务链增强、语义增强

local M = {}

local task_graph = require("todo2.core.task_graph")

---------------------------------------------------------------------
-- 工具：格式化任务链上下文
---------------------------------------------------------------------
local function format_task(t)
	if not t then
		return ""
	end
	local id = t.id and ("(" .. t.id .. ")") or ""
	return string.format("- %s %s [%s:%d]", t.content or "", id, t.path or "", t.line_num or 0)
end

local function format_task_list(list)
	if not list or #list == 0 then
		return "- 无"
	end
	local out = {}
	for _, t in ipairs(list) do
		table.insert(out, format_task(t))
	end
	return table.concat(out, "\n")
end

---------------------------------------------------------------------
-- 构建任务链上下文（用于 prompt 注入）
---------------------------------------------------------------------
local function build_task_chain_context(task_id, path)
	local ctx = task_graph.get_task_context(task_id, path)
	if not ctx or not ctx.task then
		return ""
	end

	local parts = {}

	table.insert(parts, "【任务链上下文】")

	-- 当前任务
	table.insert(parts, string.format("当前任务：%s (%s)", ctx.task.content or "", ctx.task.id or ""))

	-- 父任务
	if ctx.parent then
		table.insert(parts, "父任务：")
		table.insert(parts, format_task(ctx.parent))
	end

	-- 子任务
	table.insert(parts, "子任务：")
	table.insert(parts, format_task_list(ctx.children))

	-- 兄弟任务
	table.insert(parts, "兄弟任务：")
	table.insert(parts, format_task_list(ctx.siblings))

	-- 跨文件相关任务（store/link）
	table.insert(parts, "相关任务（跨文件）：")
	table.insert(parts, format_task_list(ctx.related))

	-- 语义相似任务（embedding）
	table.insert(parts, "语义相似任务：")
	table.insert(parts, format_task_list(ctx.semantic))

	return table.concat(parts, "\n")
end

---------------------------------------------------------------------
-- 工业级 Prompt 构建（@@TODO2_PATCH@@ 协议）
---------------------------------------------------------------------
function M.build(opts)
	-- opts:
	--   task_id
	--   task_content
	--   file_path
	--   code_context
	--   replace_start
	--   replace_end

	local task_id = opts.task_id
	local file_path = opts.file_path
	local code_context = opts.code_context or ""
	local task_content = opts.task_content or ""
	local replace_start = opts.replace_start
	local replace_end = opts.replace_end

	-----------------------------------------------------------------
	-- 任务链上下文（语义增强）
	-----------------------------------------------------------------
	local task_chain = ""
	if task_id and file_path then
		task_chain = build_task_chain_context(task_id, file_path)
	end

	-----------------------------------------------------------------
	-- 工业级 Prompt（使用 @@TODO2_PATCH@@ 协议）
	-----------------------------------------------------------------
	local prompt = string.format(
		[[
你是一名专业的代码编辑助手。你的任务是根据“任务内容”，
对指定的代码区域进行**最小必要修改**，并输出完整的替换内容。

【必须严格遵守以下规则】
1. **必须保留所有未修改的原始代码**，除非任务明确要求删除。
2. **只能修改必要的部分**，不能重写整个函数或大段代码。
3. **必须输出完整的替换内容**（包括未修改的代码）。
4. **禁止省略代码、禁止简写、禁止只输出修改部分**。
5. **禁止输出解释、禁止输出代码块标记（如 ```）**。
6. 输出内容必须是纯代码。
7. 你只能修改 @@TODO2_PATCH@@ 协议指定的行范围，不得越界。

【任务内容】
%s

%s

【当前代码上下文】
（来自 %s 第 %d-%d 行）
%s

【编辑要求】
- 只修改 @@TODO2_PATCH@@ 协议指定的行范围
- 输出必须是纯代码，不要解释
- 不要使用代码块标记（如 ```）
- 必须输出完整的替换内容
- 不要包含协议头

【协议格式】
你必须严格按照以下格式输出：
@@TODO2_PATCH@@
start: %d
end: %d
:
（这里放替换后的完整代码）

请开始输出：
]],
		task_content,
		task_chain,
		file_path,
		replace_start,
		replace_end,
		code_context,
		replace_start,
		replace_end
	)

	return prompt
end

return M
