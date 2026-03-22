-- lua/todo2/ai/prompt/strategies/feature.lua
-- 新功能实现策略

local M = {}
local base = require("todo2.ai.prompt.base")
local comment = require("todo2.utils.comment")

function M.build(ctx)
	local parts = {}

	vim.list_extend(parts, base.build_header(ctx))

	parts[#parts + 1] = "## 修改要求（新功能）"
	parts[#parts + 1] = "- 按任务描述实现新功能"
	parts[#parts + 1] = "- 添加必要的注释说明"
	parts[#parts + 1] = "- 考虑边界情况和错误处理"
	parts[#parts + 1] = "- 保持与现有代码风格一致"
	parts[#parts + 1] = "- 添加适当的日志或调试信息"

	-- 动态提示注释格式
	local prefix = comment.get_prefix_by_path(ctx.path or "")
	parts[#parts + 1] = string.format("- 使用 %s 添加必要的注释", prefix)
	parts[#parts + 1] = ""

	vim.list_extend(parts, base.build_code_context(ctx))
	vim.list_extend(parts, base.build_protocol(ctx))

	return table.concat(parts, "\n")
end

return M
