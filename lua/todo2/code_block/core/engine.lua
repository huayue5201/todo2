-- lua/todo2/code_block/core/engine.lua
-- 核心引擎

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
	debug = false,
	cache_ttl = 60,
	cache_max_items = 200,
}

local blocks_cache = Cache.new({
	ttl = config.cache_ttl,
	max_items = config.cache_max_items,
})

local symbols_cache = Cache.new({
	ttl = config.cache_ttl,
	max_items = config.cache_max_items,
})

-- 提供器优先级顺序
local providers = { Treesitter, Lsp, Indent }

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

function M.get_block_at_line(bufnr, lnum)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		Types.log(config.debug, "无效的缓冲区", vim.log.levels.WARN)
		return nil
	end
	if not lnum or lnum < 1 or lnum > vim.api.nvim_buf_line_count(bufnr) then
		Types.log(config.debug, "无效的行号: " .. tostring(lnum), vim.log.levels.WARN)
		return nil
	end

	for _, p in ipairs(providers) do
		if p == Treesitter and not config.use_treesitter then
			goto continue
		end
		if p == Lsp and not config.use_lsp then
			goto continue
		end
		if p == Indent and not config.use_indent_fallback then
			goto continue
		end

		if p.supports(bufnr) then
			local block
			if p == Lsp then
				local symbols = get_cached_symbols(bufnr)
				if symbols == nil then
					-- 符号尚未就绪，异步预取；本轮降级到下一个 provider
					M.prefetch_symbols(bufnr)
					goto continue
				end
				block = p.get_block(bufnr, lnum, symbols)
			else
				block = p.get_block(bufnr, lnum)
			end

			if block then
				Types.log(
					config.debug,
					string.format("%s 获取到 %s: %s", p.name, block.type, block.name or "unnamed")
				)
				return block
			end
		end

		::continue::
	end

	Types.log(config.debug, "无法获取代码块", vim.log.levels.WARN)
	return nil
end

--- 异步版 get_block_at_line：优先 treesitter，其次等待 LSP 符号，最后缩进兜底。
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

	local function fallback_to_indent()
		if config.use_indent_fallback and Indent.supports(bufnr) then
			return Indent.get_block(bufnr, lnum)
		end
		return nil
	end

	-- 2. LSP（等待符号表就绪）
	if config.use_lsp and Lsp.supports(bufnr) then
		local symbols = M.get_symbols(bufnr)
		if symbols then
			local block = Lsp.get_block(bufnr, lnum, symbols)
			if block then
				return block
			end
		end
	end

	-- 3. 缩进兜底
	return fallback_to_indent()
end

function M.get_all_blocks(bufnr)
	local key = changedtick_key(bufnr, "blocks")
	local cached = blocks_cache:get(key)
	if cached then
		return cached
	end

	local blocks = {}
	local deferred = false

	if config.use_treesitter and Treesitter.supports(bufnr) then
		local ts_blocks = Treesitter.get_all(bufnr)
		if ts_blocks and #ts_blocks > 0 then
			blocks = ts_blocks
		end
	end

	if #blocks == 0 and config.use_lsp and Lsp.supports(bufnr) then
		local symbols = get_cached_symbols(bufnr)
		if symbols == nil then
			-- 符号尚未就绪，异步预取；本轮不缓存，避免缓存到不完整结果
			M.prefetch_symbols(bufnr)
			deferred = true
		else
			local lsp_blocks = Lsp.get_all(bufnr, symbols)
			if lsp_blocks and #lsp_blocks > 0 then
				blocks = lsp_blocks
			end
		end
	end

	if not deferred then
		blocks_cache:set(key, blocks)
	end
	return blocks
end

--- 异步版 get_all_blocks。
--- 注意：这是 async 函数，必须在任务内调用。
---@param bufnr integer
---@return CodeBlock[]
function M.get_all_blocks_async(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end

	local key = changedtick_key(bufnr, "blocks")
	local cached = blocks_cache:get(key)
	if cached then
		return cached
	end

	local function finish(blocks)
		blocks_cache:set(key, blocks)
		return blocks
	end

	-- 1. Treesitter
	if config.use_treesitter and Treesitter.supports(bufnr) then
		local ts_blocks = Treesitter.get_all(bufnr)
		if ts_blocks and #ts_blocks > 0 then
			return finish(ts_blocks)
		end
	end

	-- 2. LSP
	if config.use_lsp and Lsp.supports(bufnr) then
		local symbols = M.get_symbols(bufnr)
		if symbols then
			local lsp_blocks = Lsp.get_all(bufnr, symbols)
			if lsp_blocks and #lsp_blocks > 0 then
				return finish(lsp_blocks)
			end
		end
	end

	return finish({})
end

function M.get_block_text(bufnr, block)
	if not block or not block.start_line or not block.end_line then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, block.start_line - 1, block.end_line, false)
	if #lines == 0 then
		return nil
	end
	return table.concat(lines, "\n")
end

function M.get_block_signature(block)
	if not block then
		return nil
	end
	if block.signature then
		return block.signature
	end
	if block.first_line then
		return block.first_line
	end
	return nil
end

function M.get_block_name(block)
	if not block then
		return nil
	end
	if block.name then
		return block.name
	end

	local sig = M.get_block_signature(block)
	if not sig then
		return nil
	end

	-- 尝试从签名中提取名称
	local patterns = {
		"func%s+%b()?%s*([%w_%.]+)",
		"function%s+([%w_%.:]+)",
		"def%s+([%w_]+)",
		"class%s+([%w_]+)",
		"fn%s+([%w_]+)",
	}

	for _, pattern in ipairs(patterns) do
		local name = sig:match(pattern)
		if name then
			return name
		end
	end

	return nil
end

function M.get_block_type(block)
	if not block then
		return nil
	end
	return block.type
end

--- 将完整 CodeBlock 收敛为最小持久化上下文（见 types.to_context）
---@param block CodeBlock
---@return table|nil
M.to_context = Types.to_context

function M.is_method(block)
	if not block then
		return false
	end
	return block.type == "method" or (block.is_method == true)
end

function M.get_receiver(block)
	if not block or not M.is_method(block) then
		return nil
	end
	return block.receiver
end

function M.clear_cache(bufnr)
	if not bufnr then
		blocks_cache:clear()
		symbols_cache:clear()
		for _, task in pairs(symbols_tasks) do
			task:close()
		end
		symbols_tasks = {}
		return
	end
	local prefix = tostring(bufnr) .. ":"
	blocks_cache:clear(prefix)
	symbols_cache:clear(prefix)
	local task = symbols_tasks[bufnr]
	if task then
		task:close()
		symbols_tasks[bufnr] = nil
	end
end

function M.setup(opts)
	opts = opts or {}
	for k, v in pairs(opts) do
		config[k] = v
	end
	blocks_cache.ttl = config.cache_ttl
	blocks_cache.max_items = config.cache_max_items
	symbols_cache.ttl = config.cache_ttl
	symbols_cache.max_items = config.cache_max_items
end

function M.get_config()
	return vim.deepcopy(config)
end

return M
