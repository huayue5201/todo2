-- lua/todo2/ai/prompt/strategy_registry.lua
-- 统一策略注册系统：tag → strategy → action_type → prompt_module

local registry = {}

---------------------------------------------------------------------
-- 注册函数
---------------------------------------------------------------------
local function register(name, opts)
	registry[name] = {
		name = name,
		tags = opts.tags or {},
		action_type = opts.action_type or "completion",
		module = opts.module,
	}
end

---------------------------------------------------------------------
-- 注册所有策略（唯一来源）
---------------------------------------------------------------------

register("bug_fix", {
	tags = { "FIX", "BUG", "HOTFIX" },
	action_type = "patch",
	module = require("todo2.ai.prompt.strategies.bug_fix"),
})

register("refactor", {
	tags = { "REFACTOR", "OPTIMIZE", "CLEANUP" },
	action_type = "refactor",
	module = require("todo2.ai.prompt.strategies.refactor"),
})

register("documentation", {
	tags = { "DOC", "COMMENT", "NOTE" },
	action_type = "comment",
	module = require("todo2.ai.prompt.strategies.doc"),
})

register("comment", {
	tags = {}, -- 由 documentation 覆盖
	action_type = "comment",
	module = require("todo2.ai.prompt.strategies.comment"),
})

register("testing", {
	tags = { "TEST", "SPEC" },
	action_type = "test",
	module = require("todo2.ai.prompt.strategies.test"),
})

register("feature", {
	tags = { "FEATURE", "TODO", "ENHANCE" },
	action_type = "completion",
	module = require("todo2.ai.prompt.strategies.feature"),
})

register("default", {
	tags = {},
	action_type = "completion",
	module = require("todo2.ai.prompt.strategies.default"),
})

---------------------------------------------------------------------
-- 查找策略：根据 tag
---------------------------------------------------------------------
function registry.resolve_by_tag(tag)
	for name, s in pairs(registry) do
		for _, t in ipairs(s.tags) do
			if t == tag then
				return name
			end
		end
	end
	return "default"
end

---------------------------------------------------------------------
-- 获取策略定义
---------------------------------------------------------------------
function registry.get(name)
	return registry[name] or registry["default"]
end

return registry
