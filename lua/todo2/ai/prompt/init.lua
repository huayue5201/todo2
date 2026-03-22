-- lua/todo2/ai/prompt/init.lua
-- Prompt 模块统一入口

local M = {}

-- 加载策略模块
local strategies = {
	bug_fix = require("todo2.ai.prompt.strategies.bug_fix"),
	refactor = require("todo2.ai.prompt.strategies.refactor"),
	feature = require("todo2.ai.prompt.strategies.feature"),
	documentation = require("todo2.ai.prompt.strategies.doc"),
	testing = require("todo2.ai.prompt.strategies.test"),
	comment = require("todo2.ai.prompt.strategies.comment"),
	default = require("todo2.ai.prompt.strategies.default"),
}

-- 标签到策略的映射
local tag_strategy_map = {
	-- 修复类
	FIX = "bug_fix",
	BUG = "bug_fix",
	HOTFIX = "bug_fix",
	-- 重构类
	REFACTOR = "refactor",
	OPTIMIZE = "refactor",
	CLEANUP = "refactor",
	-- 功能类
	FEATURE = "feature",
	TODO = "feature",
	ENHANCE = "feature",
	-- 测试类
	TEST = "testing",
	SPEC = "testing",
	-- 文档类
	DOC = "documentation",
	COMMENT = "comment",
	NOTE = "comment",
}

--- 根据任务类型获取策略
--- @param task_type string
--- @return table
local function get_strategy(task_type)
	return strategies[task_type] or strategies.default
end

--- 根据标签获取策略
--- @param tags table
--- @return table
local function get_strategy_by_tags(tags)
	if not tags or #tags == 0 then
		return strategies.default
	end

	for _, tag in ipairs(tags) do
		local strategy_name = tag_strategy_map[tag]
		if strategy_name then
			return strategies[strategy_name]
		end
	end

	return strategies.default
end

--- 构建增强 Prompt（使用 context）
--- @param ctx AIContext
--- @param opts table
--- @return string
function M.build_from_context(ctx, opts)
	opts = opts or {}

	if not ctx or not ctx.task then
		return ""
	end

	-- 根据任务类型选择策略
	local task_type = ctx.task.task_type
	local strategy = nil

	if task_type and task_type ~= "unknown" then
		strategy = get_strategy(task_type)
	else
		strategy = get_strategy_by_tags(ctx.task.tags or {})
	end

	return strategy.build(ctx)
end

--- 兼容旧接口
--- @param opts table
--- @return string
function M.build(opts)
	local base = require("todo2.ai.prompt.base")
	local parts = {}

	parts[#parts + 1] = "## 任务内容"
	parts[#parts + 1] = opts.task_content or ""
	parts[#parts + 1] = ""
	parts[#parts + 1] = "## 代码上下文"
	parts[#parts + 1] = opts.code_context or ""
	parts[#parts + 1] = ""
	parts[#parts + 1] = "## 输出协议"
	parts[#parts + 1] = "@@TODO2_PATCH@@"
	parts[#parts + 1] = string.format("start: %d", opts.replace_start or 0)
	parts[#parts + 1] = string.format("end: %d", opts.replace_end or 0)
	parts[#parts + 1] = ":"
	parts[#parts + 1] = "(替换后的完整代码)"

	return table.concat(parts, "\n")
end

--- 导出工具函数
M.get_comment_style = require("todo2.ai.prompt.utils").get_comment_style

return M
