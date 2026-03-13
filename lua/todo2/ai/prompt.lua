-- lua/todo2/ai/prompt.lua
-- 构建 AI 提示词（基础 prompt：full / contextual）
local M = {}

--- 构建基础 prompt（full 模式）
--- @param todo table
function M.build_full(todo)
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
		todo.content or "",
		todo.path or "",
		todo.line or 0
	)
end

--- 构建 patch/diff 模式的上下文 prompt（当没有模板时可用）
--- @param todo table
--- @param region string|nil CODE 区域上下文
function M.build_contextual(todo, region)
	return string.format(
		[[
你是一个专业的代码生成 AI。
任务：%s
文件：%s:%d

下面是当前 CODE 区域（仅供参考）：
%s

请只输出需要新增或修改的代码片段或 diff，不要输出额外说明。
    ]],
		todo.content or "",
		todo.path or "",
		todo.line or 0,
		region or ""
	)
end

return M
