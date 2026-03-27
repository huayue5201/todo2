-- lua/todo2/ai/prompt/strategies/bug_fix.lua
local M = {}
local base = require("todo2.ai.prompt.base")
local comment = require("todo2.utils.comment")

function M.build(ctx)
	local parts = {}

	-- 任务信息
	vim.list_extend(parts, base.build_header(ctx))

	-- Bug 修复要求
	parts[#parts + 1] = "## 修改要求（Bug 修复）"
	parts[#parts + 1] = "- 定位并修复问题，保持其他功能不变"
	parts[#parts + 1] = "- 添加必要的错误处理"
	parts[#parts + 1] = "- 确保代码能正常编译运行"
	parts[#parts + 1] = "- 如果可能，添加测试用例验证修复"

	local prefix = comment.get_prefix_by_path(ctx.path or "")
	parts[#parts + 1] = string.format("- 在修复处添加注释，格式示例: %s 修复: xxx 问题", prefix)
	parts[#parts + 1] = ""

	-- 代码上下文
	vim.list_extend(parts, base.build_code_context(ctx))

	-- 输出协议（新协议）
	vim.list_extend(parts, base.build_protocol(ctx))

	return table.concat(parts, "\n")
end

return M
