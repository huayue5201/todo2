-- lua/todo2/ai/prompt/strategies/refactor.lua
local M = {}
local base = require("todo2.ai.prompt.base")
local comment = require("todo2.utils.comment")

function M.build(ctx)
	local parts = {}

	-- 任务信息
	vim.list_extend(parts, base.build_header(ctx))

	-- 重构要求
	parts[#parts + 1] = "## 修改要求（重构）"
	parts[#parts + 1] = "- 保持原有功能完全不变"
	parts[#parts + 1] = "- 优化代码结构和可读性"
	parts[#parts + 1] = "- 遵循语言最佳实践和惯用写法"
	parts[#parts + 1] = "- 提取重复代码为独立函数"
	parts[#parts + 1] = "- 简化复杂的条件逻辑"
	parts[#parts + 1] = "- 更新相关注释和文档"

	local prefix = comment.get_prefix_by_path(ctx.path or "")
	parts[#parts + 1] = string.format("- 如有必要，使用 %s 添加说明重构内容", prefix)
	parts[#parts + 1] = ""

	-- 代码上下文
	vim.list_extend(parts, base.build_code_context(ctx))

	-- 输出协议（新协议）
	vim.list_extend(parts, base.build_protocol(ctx))

	return table.concat(parts, "\n")
end

return M
