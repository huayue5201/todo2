-- lua/todo2/ai/prompt.lua
-- 构建 AI 提示词

local M = {}

--- 构建提示词
--- @param todo table TODO 任务对象
function M.build(todo)
	return string.format(
		[[
你是一个专业的代码生成 AI。
请根据以下任务内容生成对应的代码实现。

任务内容：
%s

文件路径：%s
任务行号：%d

请直接输出代码，不要解释，不要添加额外说明。
    ]],
		todo.content,
		todo.path,
		todo.line
	)
end

return M
