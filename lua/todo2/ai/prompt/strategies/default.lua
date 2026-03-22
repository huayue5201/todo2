-- lua/todo2/ai/prompt/strategies/default.lua
local M = {}
local base = require("todo2.ai.prompt.base")
local comment = require("todo2.utils.comment")

function M.build(ctx)
	local parts = {}

	vim.list_extend(parts, base.build_header(ctx))

	parts[#parts + 1] = "## 修改要求"
	parts[#parts + 1] = "- 按任务描述进行修改"
	parts[#parts + 1] = "- 保持代码风格一致"
	parts[#parts + 1] = "- 只修改必要的部分"
	parts[#parts + 1] = "- 如果需要添加注释，使用正确的注释格式"

	-- 动态提示注释格式
	local prefix = comment.get_prefix_by_path(ctx.path or "")
	parts[#parts + 1] = string.format("- 注释格式: %s", prefix)
	parts[#parts + 1] = ""

	vim.list_extend(parts, base.build_code_context(ctx))
	vim.list_extend(parts, base.build_protocol(ctx))

	return table.concat(parts, "\n")
end

return M
