-- lua/todo2/code_block/init.lua
-- 代码块识别模块入口（todo2 内部使用）。
--
-- 对外只暴露任务代码锚点真正需要的三个能力：异步定位、符号预取、上下文收敛。
-- 更细的代码块查询/语言配置请直接用子模块
-- （code_block.locator、code_block.queries）。

local Engine = require("todo2.code_block.core.engine")

local M = {}

--- 异步定位指定行所在的代码块。
---
--- 优先级 Treesitter > LSP > 缩进兜底；LSP 符号未就绪时会在任务内等待，
--- 因此能拿到最优结果而不会过早降级。
--- 注意：这是 async 函数，必须在任务内调用。
---@param bufnr integer
---@param lnum integer 1-indexed
---@return CodeBlock|nil
M.get_block_at_line_async = Engine.get_block_at_line_async

--- 预取并缓存 LSP documentSymbol 符号表（fire-and-forget）。
---@param bufnr integer
function M.prefetch_symbols(bufnr)
	return Engine.prefetch_symbols(bufnr)
end

--- 将完整 CodeBlock 收敛为最小持久化上下文（写任务存储前剥离冗余字段）。
---@param block CodeBlock
---@return table|nil
M.to_context = Engine.to_context

return M
