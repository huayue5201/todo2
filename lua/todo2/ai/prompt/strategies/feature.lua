-- lua/todo2/ai/prompt/strategies/feature.lua
-- 新功能实现策略（新协议版）

local M = {}
local base = require("todo2.ai.prompt.base")
local comment = require("todo2.utils.comment")

function M.build(ctx)
	local parts = {}

	-- 任务信息
	vim.list_extend(parts, base.build_header(ctx))

	-- 新功能要求
	parts[#parts + 1] = "## 修改要求（新功能）"
	parts[#parts + 1] = "- 按任务描述实现新功能"
	parts[#parts + 1] = "- 添加必要的注释说明"
	parts[#parts + 1] = "- 考虑边界情况和错误处理"
	parts[#parts + 1] = "- 保持与现有代码风格一致"
	parts[#parts + 1] = "- 避免引入不必要的依赖"
	parts[#parts + 1] = ""

	-- 注释格式提示
	local prefix = comment.get_prefix_by_path(ctx.path or "")
	parts[#parts + 1] = string.format("- 使用 %s 添加必要的注释", prefix)
	parts[#parts + 1] = ""

	-- 代码上下文
	vim.list_extend(parts, base.build_code_context(ctx))

	-- 输出协议（新协议）
	vim.list_extend(parts, base.build_protocol(ctx))

	return table.concat(parts, "\n")
end

return M
