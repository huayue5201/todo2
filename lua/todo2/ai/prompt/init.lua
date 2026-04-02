-- lua/todo2/ai/prompt/init.lua
-- Prompt 模块统一入口（基于 strategy_registry）

local M = {}

local registry = require("todo2.ai.prompt.strategy_registry")

---------------------------------------------------------------------
-- 根据 ctx.task 解析策略名称
---------------------------------------------------------------------
local function resolve_strategy_name(ctx)
	if not ctx or not ctx.task then
		return "default"
	end

	-- 1. 优先使用 task_type（用户显式指定）
	local task_type = ctx.task.task_type
	if task_type and task_type ~= "unknown" and registry.get(task_type) then
		return task_type
	end

	-- 2. 根据 tag 匹配策略
	for _, tag in ipairs(ctx.task.tags or {}) do
		local name = registry.resolve_by_tag(tag)
		if name then
			return name
		end
	end

	-- 3. 默认策略
	return "default"
end

---------------------------------------------------------------------
-- 构建 Prompt（返回 prompt_text + strategy_name）
---------------------------------------------------------------------
function M.build_from_context(ctx)
	local strategy_name = resolve_strategy_name(ctx)
	local strategy = registry.get(strategy_name)

	-- strategy.module 是 prompt 模块
	local prompt_text = strategy.module.build(ctx)

	return prompt_text, strategy_name
end

return M
