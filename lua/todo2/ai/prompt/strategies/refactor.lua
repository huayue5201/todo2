-- lua/todo2/ai/prompt/strategies/refactor.lua
local M = {}
local base = require("todo2.ai.prompt.base")
local comment = require("todo2.utils.comment")

function M.build(ctx)
	local parts = {}

	vim.list_extend(parts, base.build_header(ctx))

	parts[#parts + 1] = "## 修改要求（重构）"
	parts[#parts + 1] = "- **保持原有功能完全不变**"
	parts[#parts + 1] = "- 优化代码结构和可读性"
	parts[#parts + 1] = "- 遵循语言最佳实践和惯用写法"
	parts[#parts + 1] = "- 提取重复代码为独立函数"
	parts[#parts + 1] = "- 简化复杂的条件逻辑"
	parts[#parts + 1] = "- 更新相关注释和文档"

	local prefix = comment.get_prefix_by_path(ctx.path or "")
	parts[#parts + 1] = string.format("- 重构后如有必要，添加 %s 说明重构内容", prefix)
	parts[#parts + 1] = ""

	vim.list_extend(parts, base.build_code_context(ctx))
	vim.list_extend(parts, base.build_protocol(ctx))

	return table.concat(parts, "\n")
end

return M
