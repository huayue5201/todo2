-- lua/todo2/ai/prompt/base.lua
-- 新协议版基础 Prompt 模板（无冗余、无旧格式）

local M = {}
local utils = require("todo2.ai.prompt.utils")
local comment = require("todo2.utils.comment")

---------------------------------------------------------------------
-- 任务信息
---------------------------------------------------------------------
function M.build_header(ctx)
	local parts = {}

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
		parts[#parts + 1] = ""
	end

	-- 语义相似任务
	if #ctx.semantic > 0 then
		parts[#parts + 1] = "## 语义相似任务（参考）"
		for _, sem in ipairs(ctx.semantic) do
			local sim = sem.similarity and string.format(" [相似度: %.0f%%]", sem.similarity * 100) or ""
			parts[#parts + 1] = string.format("- %s%s", sem.content or "", sim)
		end
		parts[#parts + 1] = ""
	end

	return parts
end

---------------------------------------------------------------------
-- 代码上下文
---------------------------------------------------------------------
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

	if ctx.code then
		parts[#parts + 1] = "```" .. (ctx.lang or "")
		parts[#parts + 1] = ctx.code
		parts[#parts + 1] = "```"
		parts[#parts + 1] = ""
	end

	return parts
end

---------------------------------------------------------------------
-- 新协议：TODO2 PATCH PROTOCOL v2
---------------------------------------------------------------------
function M.build_protocol(ctx)
	local parts = {}

	local start_line = ctx.start_line or 0
	local end_line = ctx.end_line or 0
	local signature_hash = ctx.block and ctx.block.signature_hash or ""
	local signature_text = ctx.block and ctx.block.signature or ""
	local mode = "line_range"

	parts[#parts + 1] = "## 输出协议"
	parts[#parts + 1] = "【重要】你必须严格按照以下格式返回修改后的代码，包括所有标记："
	parts[#parts + 1] = ""

	-- 添加格式示例
	parts[#parts + 1] = "格式示例："
	parts[#parts + 1] = "<<<TODO2_PATCH_BEGIN>>>"
	parts[#parts + 1] = "start=10"
	parts[#parts + 1] = "end=20"
	parts[#parts + 1] = "signature_hash=2ac06faa"
	parts[#parts + 1] = "mode=line_range"
	parts[#parts + 1] = "signature=func Hello()"
	parts[#parts + 1] = "<<<TODO2_PATCH_HEADER>>>"
	parts[#parts + 1] = "<<<TODO2_PATCH_CODE>>>"
	parts[#parts + 1] = "func hello() {"
	parts[#parts + 1] = '    println("Hello");'
	parts[#parts + 1] = "}"
	parts[#parts + 1] = "<<<TODO2_PATCH_END>>>"
	parts[#parts + 1] = ""

	parts[#parts + 1] = "现在请按照上述格式返回你的修改，使用以下具体值："
	parts[#parts + 1] = ""
	parts[#parts + 1] = "<<<TODO2_PATCH_BEGIN>>>"
	parts[#parts + 1] = string.format("start=%d", start_line)
	parts[#parts + 1] = string.format("end=%d", end_line)
	if signature_hash ~= "" then
		parts[#parts + 1] = string.format("signature_hash=%s", signature_hash)
	end
	parts[#parts + 1] = string.format("mode=%s", mode)

	-- 添加 signature 字段（重要！）
	if signature_text ~= "" then
		parts[#parts + 1] = string.format("signature=%s", signature_text)
	end

	parts[#parts + 1] = "<<<TODO2_PATCH_HEADER>>>"
	parts[#parts + 1] = "<<<TODO2_PATCH_CODE>>>"
	parts[#parts + 1] = "(在这里放置修改后的完整代码)"
	parts[#parts + 1] = "<<<TODO2_PATCH_END>>>"
	parts[#parts + 1] = ""

	parts[#parts + 1] = "注意："
	parts[#parts + 1] = "1. 必须包含所有 <<<TODO2_PATCH_...>>> 标记"
	parts[#parts + 1] = "2. 将 (在这里放置修改后的完整代码) 替换为实际的代码"
	parts[#parts + 1] = "3. 不要添加任何额外说明文字"

	return parts
end

---------------------------------------------------------------------
-- 注释格式提示（COMMENT 类任务使用）
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 构建完整 Prompt（策略模块会组合）
---------------------------------------------------------------------
function M.build_full(ctx, opts)
	opts = opts or {}
	local parts = {}

	vim.list_extend(parts, M.build_header(ctx))

	if opts.include_code ~= false then
		vim.list_extend(parts, M.build_code_context(ctx))
	end

	if opts.include_comment_hint then
		vim.list_extend(parts, M.build_comment_hint(ctx))
	end

	if opts.include_protocol ~= false then
		vim.list_extend(parts, M.build_protocol(ctx))
	end

	return table.concat(parts, "\n")
end

---------------------------------------------------------------------
-- 简化 Prompt（用于简单任务）
---------------------------------------------------------------------
function M.build_simple(ctx)
	local parts = {}

	parts[#parts + 1] = string.format("任务: %s", ctx.task.content or "")
	parts[#parts + 1] = ""
	parts[#parts + 1] = "代码:"
	parts[#parts + 1] = "```" .. (ctx.lang or "")
	parts[#parts + 1] = ctx.code or ""
	parts[#parts + 1] = "```"
	parts[#parts + 1] = ""

	parts[#parts + 1] = "<<<TODO2_PATCH_BEGIN>>>"
	parts[#parts + 1] = string.format("start=%d", ctx.start_line or 0)
	parts[#parts + 1] = string.format("end=%d", ctx.end_line or 0)
	parts[#parts + 1] = "mode=line_range"
	parts[#parts + 1] = "<<<TODO2_PATCH_HEADER>>>"
	parts[#parts + 1] = "<<<TODO2_PATCH_CODE>>>"
	parts[#parts + 1] = "(替换后的完整代码)"
	parts[#parts + 1] = "<<<TODO2_PATCH_END>>>"

	return table.concat(parts, "\n")
end

return M
