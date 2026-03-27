-- lua/todo2/ai/prompt/strategies/comment.lua
-- 只添加注释，不改逻辑（新协议版）

local M = {}
local base = require("todo2.ai.prompt.base")
local comment = require("todo2.utils.comment")

function M.build(ctx)
	local parts = {}

	-- 任务信息
	vim.list_extend(parts, base.build_header(ctx))

	-- 注释添加要求
	local prefix = comment.get_prefix_by_path(ctx.path or "")
	local block_prefix, block_suffix = comment.get_comment_parts(vim.fn.bufadd(ctx.path))
	local has_multiline = block_suffix and block_suffix ~= ""

	parts[#parts + 1] = "## 修改要求（添加注释）"
	parts[#parts + 1] = "- 只添加注释，不修改任何代码逻辑"
	if has_multiline then
		parts[#parts + 1] = string.format("- 文件支持多行注释: %s ... %s", block_prefix, block_suffix)
		parts[#parts + 1] = "- 函数/类使用多行注释块"
	end
	parts[#parts + 1] = string.format("- 单行注释使用: %s", prefix)
	parts[#parts + 1] = "- 函数注释放在定义上方，说明功能和参数"
	parts[#parts + 1] = "- 复杂逻辑前添加解释性注释"
	parts[#parts + 1] = "- TODO/FIXME 标记使用标准格式"
	parts[#parts + 1] = ""

	-- 简单注释示例
	parts[#parts + 1] = "## 注释示例"
	if has_multiline then
		parts[#parts + 1] = string.format("%s", block_prefix)
		parts[#parts + 1] = "  FunctionName 函数说明"
		parts[#parts + 1] = "  @param param1 参数说明"
		parts[#parts + 1] = "  @return 返回值说明"
		parts[#parts + 1] = string.format("%s", block_suffix)
		parts[#parts + 1] = ""
	end
	parts[#parts + 1] = string.format("%s 这是一个单行注释示例", prefix)
	parts[#parts + 1] = string.format("%s TODO: 需要优化的地方", prefix)
	parts[#parts + 1] = string.format("%s FIXME: 这里需要修复", prefix)
	parts[#parts + 1] = ""

	-- 代码上下文
	vim.list_extend(parts, base.build_code_context(ctx))

	-- 输出协议（新协议）
	vim.list_extend(parts, base.build_protocol(ctx))

	return table.concat(parts, "\n")
end

return M
