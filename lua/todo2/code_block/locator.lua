-- lua/todo2/code_block/locator.lua
-- 结构化定位：用 treesitter 按「块类型 + 名称」查找代码块的起始行。
--
-- 用于代码标记的行号重定位。相比「在原始文本里找签名子串」，结构化查找
-- 不会命中注释 / 字符串里出现的同名片段。treesitter 不可用或无匹配时返回
-- 空结果，由调用方退化到字符串匹配。

local M = {}

local Treesitter = require("todo2.code_block.providers.treesitter")
local Queries = require("todo2.code_block.queries")

--- 用给定 buffer 收集匹配 (name, block_type) 的块起始行（1-based）
---@param bufnr number
---@param name string|nil
---@param block_type string|nil
---@return number[]
local function collect(bufnr, name, block_type)
	local out = {}
	for _, b in ipairs(Treesitter.get_all(bufnr)) do
		local name_ok = not name or name == "" or b.name == name
		local type_ok = not block_type or block_type == "" or b.type == block_type
		if name_ok and type_ok then
			out[#out + 1] = b.start_line
		end
	end
	return out
end

--- 找到指向该路径、且已加载的 buffer
---@param path string
---@return number|nil
local function loaded_buffer(path)
	local buf = vim.fn.bufnr(path)
	if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
		return buf
	end
	return nil
end

--- 文件未打开在 buffer 中时，用临时 scratch buffer 复用 provider 的解析逻辑
---@param lines string[]
---@param ft string|nil
---@param name string|nil
---@param block_type string|nil
---@return number[]
local function collect_via_scratch(lines, ft, name, block_type)
	if not ft or ft == "" or not Queries.get(ft) then
		return {}
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].filetype = ft
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local ok, res = pcall(collect, buf, name, block_type)
	pcall(vim.api.nvim_buf_delete, buf, { force = true })

	if ok and type(res) == "table" then
		return res
	end
	return {}
end

--- 查找与 (name, block_type) 匹配的块起始行（1-based）。
--- treesitter 不可用 / 无匹配时返回空表，调用方应退化到字符串匹配。
---@param opts { path?: string, lines?: string[], filetype?: string, name?: string, block_type?: string }
---@return number[] candidates
function M.find_block_starts(opts)
	opts = opts or {}
	local name, block_type = opts.name, opts.block_type
	if (not name or name == "") and (not block_type or block_type == "") then
		return {}
	end

	local path = opts.path
	if path and path ~= "" then
		local buf = loaded_buffer(path)
		if buf then
			local ok, res = pcall(collect, buf, name, block_type)
			if ok and type(res) == "table" then
				return res
			end
		end
	end

	if opts.lines and #opts.lines > 0 then
		local ft = opts.filetype
		if not ft and path and path ~= "" then
			local ok, matched = pcall(vim.filetype.match, { filename = path })
			ft = ok and matched or nil
		end
		return collect_via_scratch(opts.lines, ft, name, block_type)
	end

	return {}
end

--- 从候选中选出「hint 之上、离它最近」的一个（代码块起点必在任务行之前）；
--- 上方没有则取下方最近的一个。
---@param candidates number[]
---@param hint number
---@return number|nil
function M.nearest_above(candidates, hint)
	local above, below
	for _, i in ipairs(candidates) do
		if i <= hint then
			if not above or i > above then
				above = i
			end
		elseif not below or i < below then
			below = i
		end
	end
	return above or below
end

return M
