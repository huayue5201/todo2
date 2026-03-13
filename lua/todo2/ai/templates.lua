-- lua/todo2/ai/templates.lua
-- 模板注册、匹配与 prompt 生成
local M = {}

-- 模板注册表：name -> { pattern, keywords, estimate }
M.registry = {
	fn = {
		pattern = "function %s(%s)\n    %s\nend",
		keywords = { "函数", "返回", "计算", "处理" },
		estimate = 30,
	},
	util = {
		pattern = "-- %s\nfunction %s(%s)\n    %s\nend",
		keywords = { "工具", "辅助", "格式化" },
		estimate = 25,
	},
	api = {
		pattern = "-- %s\n-- @param %s\n-- @return %s\nfunction %s(%s)\n    %s\nend",
		keywords = { "接口", "API", "端点", "请求" },
		estimate = 40,
	},
	test = {
		pattern = "function test_%s()\n    -- setup\n    %s\n\n    -- run\n    %s\n\n    -- assert\n    %s\nend",
		keywords = { "测试", "断言", "验证" },
		estimate = 45,
	},
}

--- 根据任务内容选择最合适的模板名（返回 nil 表示不使用模板）
--- @param todo_content string
function M.detect(todo_content)
	if not todo_content or todo_content == "" then
		return nil
	end
	local best, best_score = nil, 0
	for name, t in pairs(M.registry) do
		local score = 0
		for _, kw in ipairs(t.keywords) do
			if todo_content:find(kw, 1, true) then
				score = score + 1
			end
		end
		if score > best_score then
			best, best_score = name, score
		end
	end
	return best_score > 0 and best or nil
end

--- 使用模板生成 prompt（模板只负责“结构”，要求模型填充占位）
--- @param todo table
--- @param name string 模板名
function M.build_prompt(todo, name)
	local t = M.registry[name]
	if not t then
		return nil
	end
	return string.format(
		[[
任务：%s

使用以下模板结构生成代码（只填充模板中的占位符）：

模板结构：
%s

要求：
1. 保持模板结构不变
2. 只填充模板中的占位符
3. 直接返回填充后的完整代码，不要解释或添加额外说明
    ]],
		todo.content or "",
		t.pattern
	)
end

return M
