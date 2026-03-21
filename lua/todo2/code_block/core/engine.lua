-- lua/todo2/code_block/core/engine.lua
-- 核心引擎

local Types = require("todo2.code_block.core.types")
local Cache = require("todo2.code_block.core.cache")

local Treesitter = require("todo2.code_block.providers.treesitter")
local Lsp = require("todo2.code_block.providers.lsp")
local Indent = require("todo2.code_block.providers.indent")

local M = {}

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

local function changedtick_key(bufnr, suffix)
	local tick = vim.b[bufnr].changedtick or 0
	return string.format("%d:%d:%s", bufnr, tick, suffix)
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
			local block = p.get_block(bufnr, lnum)
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

function M.get_all_blocks(bufnr)
	local key = changedtick_key(bufnr, "blocks")
	local cached = blocks_cache:get(key)
	if cached then
		return cached
	end

	local blocks = {}

	if config.use_treesitter and Treesitter.supports(bufnr) then
		local ts_blocks = Treesitter.get_all(bufnr)
		if ts_blocks and #ts_blocks > 0 then
			blocks = ts_blocks
		end
	end

	if #blocks == 0 and config.use_lsp and Lsp.supports(bufnr) then
		local lsp_blocks = Lsp.get_all(bufnr)
		if lsp_blocks and #lsp_blocks > 0 then
			blocks = lsp_blocks
		end
	end

	blocks_cache:set(key, blocks)
	return blocks
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
	if block.text then
		return block.text:match("^[^\n]+")
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
		return
	end
	local prefix = tostring(bufnr) .. ":"
	blocks_cache:clear(prefix)
	symbols_cache:clear(prefix)
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
