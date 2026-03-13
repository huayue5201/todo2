-- lua/todo2/ai/prompt.lua
-- 任务驱动智能编辑器模式的 Prompt 构建器（REPLACE 模式）

local M = {}

---------------------------------------------------------------------
-- 构建 Prompt（基于 TODO 语义 + CODE 上下文）
---------------------------------------------------------------------
--- @param todo table 任务对象（包含 todo.content）
--- @param code_link table 代码链接对象（包含 path/line）
--- @param ctx table 上下文对象（来自 ai/context.collect）
--- @return string prompt
function M.build(todo, code_link, ctx)
	local task = todo.content or ""
	local func = ctx.func or ""
	local start_line = ctx.start_line or code_link.line
	local end_line = ctx.end_line or code_link.line

	return string.format(
		[[
你是一名专业的代码编辑器。你的任务是根据用户的 TODO 需求，修改现有代码。

【任务内容】
%s

【当前代码上下文】
（来自 %s 第 %d 行）
%s

【你的目标】
请根据任务内容，对上述代码进行修改。
你必须只输出一个补丁，格式如下：

REPLACE %d-%d:
<新的代码>

要求：
1. 只输出补丁，不要解释。
2. 不要添加额外说明。
3. 不要输出代码块标记（如 ```）。
4. 新的代码必须是完整、可编译的。
5. 保持原有缩进风格。

现在开始生成补丁。
]],
		task,
		code_link.path,
		code_link.line,
		func,
		start_line,
		end_line
	)
end

return M
