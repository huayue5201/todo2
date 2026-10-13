-- lua/todo2/code_block/core/engine.lua
-- 代码块识别引擎：为任务自动记录所在代码块（函数/类/方法等）。
--
-- 只保留 todo2 内部实际使用的入口（async 定位 + 符号预取 + 上下文收敛）。
-- 后端优先级：Treesitter > LSP > 缩进兜底。

local Types = require("todo2.code_block.core.types")
local Cache = require("todo2.code_block.core.cache")

local Treesitter = require("todo2.code_block.providers.treesitter")
local Lsp = require("todo2.code_block.providers.lsp")
local Indent = require("todo2.code_block.providers.indent")

local M = {}

local async = vim.async

local config = {
	use_treesitter = true,
	use_lsp = true,
	use_indent_fallback = true,
	cache_ttl = 60,
	cache_max_items = 200,
}

local symbols_cache = Cache.new({
	ttl = config.cache_ttl,
	max_items = config.cache_max_items,
})

-- LSP symbols 在途请求（按 buffer 去重：并发调用共享同一个任务）
local symbols_tasks = {}

local function changedtick_key(bufnr, suffix)
	local tick = vim.b[bufnr].changedtick or 0
	return string.format("%d:%d:%s", bufnr, tick, suffix)
end

local function symbols_key(bufnr)
	return changedtick_key(bufnr, "symbols")
end

local function get_cached_symbols(bufnr)
	return symbols_cache:get(symbols_key(bufnr))
end

--- 获取符号表（缓存优先；并发请求共享同一个任务）。
--- 注意：这是 async 函数，必须在任务内调用。
---@param bufnr integer
---@return any[]|nil
function M.get_symbols(bufnr)
	if not config.use_lsp or not Lsp.supports(bufnr) then
		return nil
	end

	local cached = get_cached_symbols(bufnr)
	if cached ~= nil then
		return cached
	end

	local inflight = symbols_tasks[bufnr]
	if inflight then
		return async.await(inflight)
	end

	local task = async.run(function()
		local symbols = Lsp.get_symbols(bufnr)
		symbols_tasks[bufnr] = nil
		if symbols ~= nil then
			symbols_cache:set(symbols_key(bufnr), symbols)
		end
		return symbols
	end)
	symbols_tasks[bufnr] = task

	return async.await(task)
end

--- 后台预取符号表（fire-and-forget），结果后续可从缓存同步取到。
---@param bufnr integer
function M.prefetch_symbols(bufnr)
	if not config.use_lsp or not Lsp.supports(bufnr) then
		return
	end
	if get_cached_symbols(bufnr) ~= nil or symbols_tasks[bufnr] then
		return
	end

	async
		.run(function()
			M.get_symbols(bufnr)
		end)
		:detach()
end

--- 异步定位指定行所在的代码块：优先 treesitter，其次等待 LSP 符号，最后缩进兜底。
--- 注意：这是 async 函数，必须在任务内调用。
---@param bufnr integer
---@param lnum integer
---@return CodeBlock|nil
function M.get_block_at_line_async(bufnr, lnum)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	if not lnum or lnum < 1 or lnum > vim.api.nvim_buf_line_count(bufnr) then
		return nil
	end

	-- 1. Treesitter（同步，最高优先级）
	if config.use_treesitter and Treesitter.supports(bufnr) then
		local block = Treesitter.get_block(bufnr, lnum)
		if block then
			return block
		end
	end

	-- 2. LSP（等待符号表就绪）
	if config.use_lsp and Lsp.supports(bufnr) then
		local symbols = M.get_symbols(bufnr)
		-- M.get_symbols 内部 await 了任务，恢复时可能处于 fast event context；
		-- 后面的 Lsp.get_block / 缩进兜底都会碰 buffer，必须先切回安全上下文。
		async.await(vim.schedule)
		if symbols then
			local block = Lsp.get_block(bufnr, lnum, symbols)
			if block then
				return block
			end
		end
	end

	-- 3. 缩进兜底
	if config.use_indent_fallback and Indent.supports(bufnr) then
		return Indent.get_block(bufnr, lnum)
	end
	return nil
end

--- 将完整 CodeBlock 收敛为最小持久化上下文（见 types.to_context）
---@param block CodeBlock
---@return table|nil
M.to_context = Types.to_context

return M
