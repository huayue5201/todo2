-- lua/todo2/ai/prompt/base.lua
-- 基础 Prompt 模板，提供通用部分

local M = {}
local utils = require("todo2.ai.prompt.utils")
local comment = require("todo2.utils.comment")

--- 构建通用 Prompt 头部（任务信息 + 任务链）
--- @param ctx AIContext
--- @return string[]
function M.build_header(ctx)
	local parts = {}

	-- 任务基本信息
	parts[#parts + 1] = "## 任务信息"
	parts[#parts + 1] = string.format("**内容**: %s", ctx.task.content or "")
	parts[#parts + 1] = string.format("**标签**: %s", table.concat(ctx.task.tags or {}, ", "))
	if ctx.task.primary_tag then
		parts[#parts + 1] = string.format("**主要标签**: %s", ctx.task.primary_tag)
	end
	parts[#parts + 1] = ""

	-- 父任务
	if ctx.parent then
		parts[#parts + 1] = "## 父任务"
		parts[#parts + 1] = utils.format_task_node(ctx.parent)
		parts[#parts + 1] = ""
	end

	-- 子任务
	if #ctx.children > 0 then
		parts[#parts + 1] = "## 子任务（影响范围）"
		parts[#parts + 1] = utils.format_task_list(ctx.children)
		if ctx.meta and ctx.meta.children_truncated then
			parts[#parts + 1] = string.format("- ... 还有 %d 个子任务", ctx.meta.children_truncated_count or 0)
		end
		parts[#parts + 1] = ""
	end

	-- 兄弟任务
	if #ctx.siblings > 0 then
		parts[#parts + 1] = "## 同级任务（保持一致性）"
		parts[#parts + 1] = utils.format_task_list(ctx.siblings)
		parts[#parts + 1] = ""
	end

	-- 语义相似任务
	if #ctx.semantic > 0 then
		parts[#parts + 1] = "## 语义相似任务（参考）"
		for _, sem in ipairs(ctx.semantic) do
			local sim = sem.similarity and string.format(" [相似度: %.0f%%]", sem.similarity * 100) or ""
			parts[#parts + 1] = string.format("- %s%s", sem.content or "", sim)
		end
		if ctx.meta and ctx.meta.semantic_truncated then
			parts[#parts + 1] = string.format("- ... 还有 %d 个相似任务", ctx.meta.semantic_truncated_count or 0)
		end
		parts[#parts + 1] = ""
	end

	-- 相关任务
	if #ctx.related > 0 then
		parts[#parts + 1] = "## 手动关联任务"
		parts[#parts + 1] = utils.format_task_list(ctx.related)
		parts[#parts + 1] = ""
	end

	return parts
end

--- 构建代码上下文部分
--- @param ctx AIContext
--- @return string[]
function M.build_code_context(ctx)
	local parts = {}

	parts[#parts + 1] = "## 代码上下文"
	parts[#parts + 1] = string.format("**文件**: %s", ctx.path or "unknown")
	parts[#parts + 1] = string.format("**语言**: %s", ctx.lang or "unknown")
	parts[#parts + 1] = string.format("**范围**: 第 %d-%d 行", ctx.start_line or 0, ctx.end_line or 0)

	if ctx.block then
		if ctx.block.name then
			parts[#parts + 1] = string.format("**代码块**: %s", ctx.block.name)
		end
		if ctx.block.type then
			parts[#parts + 1] = string.format("**块类型**: %s", ctx.block.type)
		end
		if ctx.block.signature then
			parts[#parts + 1] = string.format("**签名**: %s", ctx.block.signature)
		end
	end
	parts[#parts + 1] = ""

	-- 代码内容
	if ctx.code then
		parts[#parts + 1] = "```" .. (ctx.lang or "")
		parts[#parts + 1] = ctx.code
		parts[#parts + 1] = "```"
		parts[#parts + 1] = ""
	end

	return parts
end

--- 构建输出协议部分
--- @param ctx AIContext
--- @return string[]
function M.build_protocol(ctx)
	local parts = {}

	parts[#parts + 1] = "## 输出协议"
	parts[#parts + 1] = "请严格按照以下格式返回修改后的完整代码："
	parts[#parts + 1] = ""
	parts[#parts + 1] = "@@TODO2_PATCH@@"
	parts[#parts + 1] = string.format("start: %d", ctx.start_line or 0)
	parts[#parts + 1] = string.format("end: %d", ctx.end_line or 0)
	parts[#parts + 1] = ":"
	parts[#parts + 1] = "(替换后的完整代码)"

	return parts
end

--- 构建通用规则部分
--- @param ctx AIContext
--- @return string[]
function M.build_rules(ctx)
	local parts = {}

	parts[#parts + 1] = "## 通用规则"
	parts[#parts + 1] = "1. 必须保留所有未修改的原始代码"
	parts[#parts + 1] = "2. 只能修改必要的部分"
	parts[#parts + 1] = "3. 必须输出完整的替换内容"
	parts[#parts + 1] = "4. 禁止省略代码、禁止简写"
	parts[#parts + 1] = '5. **禁止输出任何解释文字**（如"好的"、"这是修改后的代码"等）'
	parts[#parts + 1] = "6. **禁止输出代码块标记**（如 ```go、```）"
	parts[#parts + 1] = "7. 响应必须以 @@TODO2_PATCH@@ 开头"
	parts[#parts + 1] = ""

	return parts
end

--- 构建注释相关提示
--- @param ctx AIContext
--- @return string[]
function M.build_comment_hint(ctx)
	local parts = {}
	local prefix = comment.get_prefix_by_path(ctx.path or "")
	local block_prefix, block_suffix = comment.get_comment_parts(vim.fn.bufadd(ctx.path))
	local has_multiline = block_suffix and block_suffix ~= ""

	parts[#parts + 1] = "## 注释格式提示"
	parts[#parts + 1] = string.format("- 当前文件使用注释前缀: %s", prefix)

	if has_multiline then
		parts[#parts + 1] = string.format("- 支持多行注释: %s ... %s", block_prefix, block_suffix)
	end
	parts[#parts + 1] = ""

	return parts
end

--- 构建错误处理提示
--- @param ctx AIContext
--- @return string[]
function M.build_error_handling_hint(ctx)
	local parts = {}

	parts[#parts + 1] = "## 错误处理要求"
	parts[#parts + 1] = "- 添加适当的错误处理"
	parts[#parts + 1] = "- 使用语言惯用的错误处理模式"
	parts[#parts + 1] = "- 错误信息要清晰描述问题"
	parts[#parts + 1] = ""

	return parts
end

--- 构建性能优化提示
--- @param ctx AIContext
--- @return string[]
function M.build_performance_hint(ctx)
	local parts = {}

	parts[#parts + 1] = "## 性能要求"
	parts[#parts + 1] = "- 避免不必要的内存分配"
	parts[#parts + 1] = "- 使用高效的算法和数据结构"
	parts[#parts + 1] = "- 注意循环和递归的复杂度"
	parts[#parts + 1] = ""

	return parts
end

--- 构建安全提示
--- @param ctx AIContext
--- @return string[]
function M.build_security_hint(ctx)
	local parts = {}

	parts[#parts + 1] = "## 安全要求"
	parts[#parts + 1] = "- 验证所有外部输入"
	parts[#parts + 1] = "- 避免 SQL 注入、XSS 等常见漏洞"
	parts[#parts + 1] = "- 使用安全的 API 和模式"
	parts[#parts + 1] = ""

	return parts
end

--- 构建可测试性提示
--- @param ctx AIContext
--- @return string[]
function M.build_testability_hint(ctx)
	local parts = {}

	parts[#parts + 1] = "## 可测试性要求"
	parts[#parts + 1] = "- 代码应易于测试"
	parts[#parts + 1] = "- 避免硬编码依赖"
	parts[#parts + 1] = "- 使用依赖注入等模式"
	parts[#parts + 1] = ""

	return parts
end

--- 构建代码示例部分
--- @param ctx AIContext
--- @param examples table 示例列表
--- @return string[]
function M.build_examples(ctx, examples)
	if not examples or #examples == 0 then
		return {}
	end

	local parts = {}
	parts[#parts + 1] = "## 代码示例"
	parts[#parts + 1] = "参考以下示例的代码风格："
	parts[#parts + 1] = ""

	for _, example in ipairs(examples) do
		if example.title then
			parts[#parts + 1] = string.format("### %s", example.title)
		end
		parts[#parts + 1] = "```" .. (example.lang or ctx.lang or "")
		parts[#parts + 1] = example.code
		parts[#parts + 1] = "```"
		parts[#parts + 1] = ""
	end

	return parts
end

--- 构建完整的基础 Prompt（组合所有部分）
--- @param ctx AIContext
--- @param opts table 选项，可以控制包含哪些部分
--- @return string
function M.build_full(ctx, opts)
	opts = opts or {}
	local parts = {}

	-- 头部
	vim.list_extend(parts, M.build_header(ctx))

	-- 规则（可选）
	if opts.include_rules ~= false then
		vim.list_extend(parts, M.build_rules(ctx))
	end

	-- 注释提示（可选）
	if opts.include_comment_hint then
		vim.list_extend(parts, M.build_comment_hint(ctx))
	end

	-- 错误处理提示（可选）
	if opts.include_error_handling then
		vim.list_extend(parts, M.build_error_handling_hint(ctx))
	end

	-- 性能提示（可选）
	if opts.include_performance then
		vim.list_extend(parts, M.build_performance_hint(ctx))
	end

	-- 安全提示（可选）
	if opts.include_security then
		vim.list_extend(parts, M.build_security_hint(ctx))
	end

	-- 代码上下文
	if opts.include_code ~= false then
		vim.list_extend(parts, M.build_code_context(ctx))
	end

	-- 示例（可选）
	if opts.examples then
		vim.list_extend(parts, M.build_examples(ctx, opts.examples))
	end

	-- 输出协议
	if opts.include_protocol ~= false then
		vim.list_extend(parts, M.build_protocol(ctx))
	end

	return table.concat(parts, "\n")
end

--- 构建简化版 Prompt（只包含核心信息）
--- @param ctx AIContext
--- @return string
function M.build_simple(ctx)
	local parts = {}

	parts[#parts + 1] = string.format("任务: %s", ctx.task.content or "")
	parts[#parts + 1] = ""
	parts[#parts + 1] = "代码:"
	parts[#parts + 1] = "```" .. (ctx.lang or "")
	parts[#parts + 1] = ctx.code or ""
	parts[#parts + 1] = "```"
	parts[#parts + 1] = ""
	parts[#parts + 1] = "@@TODO2_PATCH@@"
	parts[#parts + 1] = string.format("start: %d", ctx.start_line or 0)
	parts[#parts + 1] = string.format("end: %d", ctx.end_line or 0)
	parts[#parts + 1] = ":"

	return table.concat(parts, "\n")
end

return M
