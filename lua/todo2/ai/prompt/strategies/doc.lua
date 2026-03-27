-- lua/todo2/ai/prompt/strategies/doc.lua
-- 文档 / 注释增强策略（新协议版）

local M = {}
local base = require("todo2.ai.prompt.base")
local comment = require("todo2.utils.comment")

function M.build(ctx)
	local parts = {}

	-- 任务信息
	vim.list_extend(parts, base.build_header(ctx))

	-- 注释 / 文档要求
	local prefix = comment.get_prefix_by_path(ctx.path or "")
	local block_prefix, block_suffix = comment.get_comment_parts(vim.fn.bufadd(ctx.path))

	parts[#parts + 1] = "## 修改要求（文档/注释）"
	parts[#parts + 1] = "- 为代码添加或更新注释"
	parts[#parts + 1] = "- 函数注释放在定义上方"
	parts[#parts + 1] = "- 关键逻辑注释放在代码行上方"
	parts[#parts + 1] = "- 注释要简洁、准确、有用"
	parts[#parts + 1] = "- 不修改任何现有代码逻辑"
	if block_suffix and block_suffix ~= "" then
		parts[#parts + 1] = string.format("- 多行注释格式: %s ... %s", block_prefix, block_suffix)
	else
		parts[#parts + 1] = string.format("- 单行注释格式: %s", prefix)
	end
	parts[#parts + 1] = ""

	-- 简单注释示例
	parts[#parts + 1] = "## 注释示例"
	if block_suffix and block_suffix ~= "" then
		parts[#parts + 1] = string.format("%s 这是一个函数注释示例", block_prefix)
		parts[#parts + 1] = string.format("%s 它解释函数的作用和参数", block_prefix)
		parts[#parts + 1] = string.format("%s 返回: 处理结果", block_prefix)
		parts[#parts + 1] = block_suffix
		parts[#parts + 1] = ""
		parts[#parts + 1] = string.format("%s 这是一个单行注释示例", prefix)
	else
		parts[#parts + 1] = string.format("%s 这是一个函数注释示例", prefix)
		parts[#parts + 1] = string.format("%s 它解释函数的作用和参数", prefix)
		parts[#parts + 1] = string.format("%s 返回: 处理结果", prefix)
	end
	parts[#parts + 1] = ""

	-- 代码上下文
	vim.list_extend(parts, base.build_code_context(ctx))

	-- 输出协议（新协议）
	vim.list_extend(parts, base.build_protocol(ctx))

	return table.concat(parts, "\n")
end

return M
