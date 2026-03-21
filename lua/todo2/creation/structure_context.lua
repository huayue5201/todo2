-- lua/todo2/creation/structure_context.lua
-- 轻量级结构化上下文采集器（用于 task_ctx 存储）
-- 完整代码块将在 AI 上下文构建阶段实时获取

local M = {}

local hash_utils = require("todo2.utils.hash")
local code_block = require("todo2.code_block")

local VERSION = 4 -- ✅ 升级到版本4

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

local function validate_line_number(bufnr, lnum)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "缓冲区无效"
	end
	local total = vim.api.nvim_buf_line_count(bufnr)
	if not lnum or lnum < 1 or lnum > total then
		return false, string.format("行号 %d 超出范围（总行数：%d）", lnum or 0, total)
	end
	return true, "OK"
end

--- 构建轻量级结构指纹
---@param info table 代码块信息
---@param file_path string 文件路径
---@return table
local function build_light_fingerprint(info, file_path)
	local signature = info.signature or ""
	local key = table.concat({
		file_path or "",
		info.type or "",
		info.name or "",
		tostring(info.start_line or 0),
		tostring(info.end_line or 0),
		signature,
	}, "|")

	return {
		hash = hash_utils.hash(key),
		signature_hash = info.signature_hash or hash_utils.hash(signature),
		window_hash = hash_utils.hash(info.signature or ""),
		line_count = 5, -- 保持兼容
	}
end

---------------------------------------------------------------------
-- 核心 API：轻量级结构上下文采集
---------------------------------------------------------------------

--- 从缓冲区构建结构化上下文
---@param bufnr number 缓冲区编号
---@param lnum number 行号（1-based）
---@param filepath string|nil 可选的文件路径
---@return table|nil 结构化上下文对象
function M.build_from_buffer(bufnr, lnum, filepath)
	local ok, msg = validate_line_number(bufnr, lnum)
	if not ok then
		vim.notify("结构上下文创建失败：" .. msg, vim.log.levels.ERROR)
		return nil
	end

	local file_path = filepath
	if not file_path or file_path == "" then
		file_path = vim.api.nvim_buf_get_name(bufnr)
	end

	-------------------------------------------------------------------
	-- 1. 使用 CodeBlock Engine 获取结构节点
	-------------------------------------------------------------------
	local block = code_block.get_block_at_line(bufnr, lnum)

	if not block then
		-- 无结构节点 → 文件级 fallback
		local total = vim.api.nvim_buf_line_count(bufnr)
		local info = {
			type = "file",
			name = nil,
			signature = nil,
			signature_hash = "",
			start_line = 1,
			end_line = total,
			language = vim.bo[bufnr].filetype,
			source = "fallback",
			is_method = false,
			receiver = nil,
		}

		return {
			version = VERSION,
			code_block_info = info,
			fingerprint = build_light_fingerprint(info, file_path),
			target_file = file_path,
			target_line = lnum,
		}
	end

	-------------------------------------------------------------------
	-- 2. 构建轻量级结构信息（完整）
	-------------------------------------------------------------------
	local signature = code_block.get_block_signature(block)
	local name = code_block.get_block_name(block)
	local is_method = code_block.is_method and code_block.is_method(block) or (block.type == "method")
	local receiver = is_method and code_block.get_receiver and code_block.get_receiver(block) or nil

	local info = {
		type = block.type, -- "function" | "method" | "class" | ...
		name = name, -- "TencentDOCtwo"
		signature = signature or "", -- "func TencentDOCtwo() error"
		signature_hash = signature and hash_utils.hash(signature) or "00000000",
		start_line = block.start_line, -- 实际函数开始行
		end_line = block.end_line, -- 实际函数结束行
		language = block.lang,
		source = block.source, -- "treesitter" | "lsp" | "indent"
		is_method = is_method, -- 是否为方法
		receiver = receiver, -- 接收者类型（Go: "*Client"）
	}

	-------------------------------------------------------------------
	-- 3. 构建轻量级结构指纹
	-------------------------------------------------------------------
	local fingerprint = build_light_fingerprint(info, file_path)

	-------------------------------------------------------------------
	-- 4. 返回轻量级结构上下文
	-------------------------------------------------------------------
	return {
		version = VERSION,
		code_block_info = info,
		fingerprint = fingerprint,
		target_file = file_path,
		target_line = lnum,
	}
end

return M
