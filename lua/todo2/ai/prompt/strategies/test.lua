-- lua/todo2/ai/prompt/strategies/test.lua
-- 测试用例添加/更新策略

local M = {}
local base = require("todo2.ai.prompt.base")

function M.build(ctx)
	local parts = {}

	vim.list_extend(parts, base.build_header(ctx))

	parts[#parts + 1] = "## 修改要求（测试）"
	parts[#parts + 1] = "- 添加或更新测试用例"
	parts[#parts + 1] = "- 覆盖关键功能和边界情况"
	parts[#parts + 1] = "- 测试命名清晰描述测试内容"
	parts[#parts + 1] = "- 使用测试框架的惯用写法"
	parts[#parts + 1] = "- 确保测试独立可重复运行"

	-- 语言特定的测试框架提示
	local lang = ctx.lang or ""
	local test_framework = ""

	if lang == "go" then
		test_framework = "使用 testing 包，命名以 Test 开头"
	elseif lang == "python" then
		test_framework = "使用 pytest 或 unittest，函数以 test_ 开头"
	elseif lang == "javascript" or lang == "typescript" then
		test_framework = "使用 Jest 或 Mocha，使用 describe/it 结构"
	elseif lang == "lua" then
		test_framework = "使用 busted 或 luaunit"
	else
		test_framework = "使用语言的标准测试框架"
	end

	parts[#parts + 1] = string.format("- %s", test_framework)
	parts[#parts + 1] = ""

	vim.list_extend(parts, base.build_code_context(ctx))
	vim.list_extend(parts, base.build_protocol(ctx))

	return table.concat(parts, "\n")
end

return M
