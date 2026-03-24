-- lua/todo2/creation/structure_context.lua
-- 轻量级结构化上下文采集器（异步版本）
-- 完整代码块将在 AI 上下文构建阶段实时获取

local M = {}

local code_block = require("todo2.code_block")

local VERSION = 5

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

---------------------------------------------------------------------
-- 核心 API：异步结构上下文采集
---------------------------------------------------------------------

--- 从缓冲区构建结构化上下文（异步版本）
---@param bufnr number 缓冲区编号
---@param lnum number 行号（1-based）
---@param filepath string|nil 可选的文件路径
---@param callback function 回调函数，签名：function(err, result)
function M.build_from_buffer(bufnr, lnum, filepath, callback)
	if type(callback) ~= "function" then
		error("build_from_buffer 需要 callback 函数参数")
	end

	local ok, msg = validate_line_number(bufnr, lnum)
	if not ok then
		vim.schedule(function()
			callback(msg, nil)
		end)
		return
	end

	vim.schedule(function()
		local success, result = pcall(function()
			local file_path = filepath
			if not file_path or file_path == "" then
				file_path = vim.api.nvim_buf_get_name(bufnr)
			end

			-------------------------------------------------------------------
			-- 1. 使用 CodeBlock Engine 获取结构节点（包含精细信息）
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
					target_file = file_path,
					target_line = lnum,
					relative_line = lnum,
				}
			end

			-------------------------------------------------------------------
			-- 2. 构建结构信息（直接使用 code_block 返回的字段）
			-------------------------------------------------------------------
			local info = {
				type = block.type,
				name = block.name,
				signature = block.signature or "",
				signature_hash = block.signature_hash or "00000000",
				start_line = block.start_line,
				end_line = block.end_line,
				language = block.lang,
				source = block.source,
				is_method = block.is_method or false,
				receiver = block.receiver,
			}

			-------------------------------------------------------------------
			-- 3. 返回结构化上下文（包含精细信息）
			-------------------------------------------------------------------
			return {
				version = VERSION,
				code_block_info = info,
				target_file = file_path,
				target_line = lnum,
				relative_line = block.relative_line or (lnum - block.start_line + 1),
				inner_node = block.inner_node,
				statement = block.statement,
				ancestors = block.ancestors,
			}
		end)

		if not success then
			callback("采集失败: " .. tostring(result), nil)
		else
			callback(nil, result)
		end
	end)
end

return M
