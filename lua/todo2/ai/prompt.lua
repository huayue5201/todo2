-- lua/todo2/ai/prompt.lua
-- 工业级 Prompt：最小修改、完整替换、任务链增强、语义增强 + 对话增强

local M = {}

local task_graph = require("todo2.core.task_graph")

---------------------------------------------------------------------
-- 工具：格式化任务链上下文
---------------------------------------------------------------------
local function format_task(t)
	if not t then
		return ""
	end
	local id = t.id and ("(" .. t.id .. ")") or ""
	return string.format("- %s %s [%s:%d]", t.content or "", id, t.path or "", t.line_num or 0)
end

local function format_task_list(list)
	if not list or #list == 0 then
		return "- 无"
	end
	local out = {}
	for _, t in ipairs(list) do
		table.insert(out, format_task(t))
	end
	return table.concat(out, "\n")
end

---------------------------------------------------------------------
-- 构建任务链上下文（用于 prompt 注入）
---------------------------------------------------------------------
local function build_task_chain_context(task_id, path)
	local ctx = task_graph.get_task_context(task_id, path)
	if not ctx or not ctx.task then
		return ""
	end

	local parts = {}

	table.insert(parts, "【任务链上下文】")

	table.insert(parts, string.format("当前任务：%s (%s)", ctx.task.content or "", ctx.task.id or ""))

	if ctx.parent then
		table.insert(parts, "父任务：")
		table.insert(parts, format_task(ctx.parent))
	end

	table.insert(parts, "子任务：")
	table.insert(parts, format_task_list(ctx.children))

	table.insert(parts, "兄弟任务：")
	table.insert(parts, format_task_list(ctx.siblings))

	table.insert(parts, "相关任务（跨文件）：")
	table.insert(parts, format_task_list(ctx.related))

	table.insert(parts, "语义相似任务：")
	table.insert(parts, format_task_list(ctx.semantic))

	return table.concat(parts, "\n")
end

---------------------------------------------------------------------
-- 工业级 Prompt（@@TODO2_PATCH@@ 协议）- 增强版
---------------------------------------------------------------------
function M.build(opts)
	local task_id = opts.task_id
	local file_path = opts.file_path
	local code_context = opts.code_context or ""
	local task_content = opts.task_content or ""
	local replace_start = opts.replace_start
	local replace_end = opts.replace_end

	local task_chain = ""
	if task_id and file_path then
		task_chain = build_task_chain_context(task_id, file_path)
	end

	local prompt = string.format(
		[[
你是一名专业的代码编辑助手。你的任务是根据“任务内容”，
对指定的代码区域进行**最小必要修改**，并输出完整的替换内容。

【任务内容】
%s

%s

【当前代码上下文】
（来自 %s 第 %d-%d 行）
%s

【必须严格遵守以下规则】
1. 必须保留所有未修改的原始代码。
2. 只能修改必要的部分。
3. 必须输出完整的替换内容。
4. 禁止省略代码、禁止简写。
5. **禁止输出任何解释文字**（如"好的"、"这是修改后的代码"等）。
6. **禁止输出代码块标记**（如 ```go、```）。
7. **只能使用以下协议格式输出，不要添加任何其他内容**：

@@TODO2_PATCH@@
start: %d
end: %d
:
（这里放替换后的完整代码）

【协议格式示例】
例如，如果用户要求添加注释，你应该返回：

@@TODO2_PATCH@@
start: 10
end: 45
:
// Package spiders 包含网络爬虫相关的功能
package spiders

import (
    "bytes"
    "compress/zlib"
    "encoding/base64"
    "fmt"
    "io"
    "net/http"
    "regexp"
)

// TencentDOCtwo 获取腾讯文档的 smartsheet 数据并解压缩
func TencentDOCtwo() error {
    // 创建 HTTP 客户端
    client := &http.Client{}
    // ... 其余代码保持不变
    return nil
}

【重要警告】
- 如果你返回任何解释文字，系统将无法解析你的响应
- 如果你不严格遵守协议格式，修改将不会生效
- 你的响应必须**以 @@TODO2_PATCH@@ 开头**，以代码结尾
]],
		task_content,
		task_chain,
		file_path,
		replace_start,
		replace_end,
		code_context,
		replace_start,
		replace_end
	)

	return prompt
end

---------------------------------------------------------------------
-- 专门用于添加注释的 Prompt
---------------------------------------------------------------------
function M.build_for_comment(opts)
	local task_id = opts.task_id
	local file_path = opts.file_path
	local code_context = opts.code_context or ""
	local task_content = opts.task_content or ""
	local replace_start = opts.replace_start
	local replace_end = opts.replace_end

	local task_chain = ""
	if task_id and file_path then
		task_chain = build_task_chain_context(task_id, file_path)
	end

	local prompt = string.format(
		[[
你是一名专业的代码注释助手。你的任务是为指定的代码区域添加注释。

【任务内容】
%s

%s

【当前代码上下文】
（来自 %s 第 %d-%d 行）
%s

【注释要求】
- 使用 Go 语言的注释格式（// 或 /* */）
- 函数注释放在函数定义上方
- 关键逻辑注释放在代码行上方
- 注释要简洁、准确、有用
- **不要删除或修改任何现有代码，只添加注释**

【必须严格遵守以下协议格式】
你必须以以下格式返回添加注释后的完整代码：

@@TODO2_PATCH@@
start: %d
end: %d
:
（这里放添加注释后的完整代码）

【协议格式示例】
@@TODO2_PATCH@@
start: 10
end: 45
:
// Package spiders 包含网络爬虫相关的功能
package spiders

import (
    "bytes"
    "compress/zlib"
    "encoding/base64"
    "fmt"
    "io"
    "net/http"
    "regexp"
)

// TencentDOCtwo 获取腾讯文档的 smartsheet 数据并解压缩
func TencentDOCtwo() error {
    // 创建 HTTP 客户端
    client := &http.Client{}
    // 构建 API 请求
    req, err := http.NewRequest("GET", "https://...", nil)
    if err != nil {
        return fmt.Errorf("创建请求失败: %%w", err)
    }
    // ... 其余代码保持不变
    return nil
}

【重要警告】
- **禁止返回任何解释文字**（如"好的"、"已添加注释"等）
- **禁止添加代码块标记**（如 ```go、```）
- 你的响应必须**以 @@TODO2_PATCH@@ 开头**
- 必须返回**完整的代码块**，包括所有未修改的部分
]],
		task_content,
		task_chain,
		file_path,
		replace_start,
		replace_end,
		code_context,
		replace_start,
		replace_end
	)

	return prompt
end

---------------------------------------------------------------------
-- 对话增强版 Prompt
---------------------------------------------------------------------
function M.build_with_chat(task, messages)
	-- ⭐ 安全检查
	if not task then
		-- 如果没有任务对象，返回一个简化的 prompt
		local chat_lines = {}
		for _, msg in ipairs(messages or {}) do
			table.insert(chat_lines, string.format("%s: %s", msg.role or "unknown", msg.content or ""))
		end

		return string.format(
			[[
你是一名专业的 AI 助手，现在正在与用户进行对话。

【对话历史】
%s

【回答要求】
- 回答必须简洁、准确
- 可以提出建议、解释、推理
- 你现在是一个对话助手

请继续回答用户的问题：
]],
			table.concat(chat_lines, "\n")
		)
	end

	-- ⭐ 从新结构获取任务内容
	local task_content = task.core and task.core.content or task.content or ""

	-- ⭐ 构建任务链上下文（使用 task.id 和 task.locations.todo.path）
	local task_chain = ""
	if task.id and task.locations and task.locations.todo and task.locations.todo.path then
		task_chain = build_task_chain_context(task.id, task.locations.todo.path)
	end

	local chat_lines = {}
	for _, msg in ipairs(messages or {}) do
		table.insert(chat_lines, string.format("%s: %s", msg.role, msg.content))
	end

	return string.format(
		[[
你是一名专业的 AI 助手，现在正在与用户进行任务相关的对话。

【任务内容】
%s

%s

【对话历史】
%s

【回答要求】
- 回答必须与任务相关
- 回答必须简洁、准确
- 可以提出建议、解释、推理
- 不需要输出代码 patch
- 不需要遵守 @@TODO2_PATCH@@ 协议
- 你现在是一个对话助手，而不是代码编辑器

请继续回答用户的问题：
]],
		task_content,
		task_chain,
		table.concat(chat_lines, "\n")
	)
end

return M
