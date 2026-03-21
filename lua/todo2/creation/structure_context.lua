-- lua/todo2/creation/structure_context.lua
-- 轻量级结构化上下文采集器（异步版本）
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

---------------------------------------------------------------------
-- 核心 API：异步结构上下文采集
---------------------------------------------------------------------

--- 从缓冲区构建结构化上下文（异步版本）
---@param bufnr number 缓冲区编号
---@param lnum number 行号（1-based）
---@param filepath string|nil 可选的文件路径
---@param callback function 回调函数，签名：function(err, result)
function M.build_from_buffer(bufnr, lnum, filepath, callback)
	-- 参数验证
	if type(callback) ~= "function" then
		error("build_from_buffer 需要 callback 函数参数")
	end

	-- 验证行号
	local ok, msg = validate_line_number(bufnr, lnum)
	if not ok then
		vim.schedule(function()
			callback(msg, nil)
		end)
		return
	end

	-- 在下一个事件循环中执行，避免阻塞
	vim.schedule(function()
		-- 使用 pcall 捕获可能的错误
		local success, result = pcall(function()
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
				type = block.type,
				name = name,
				signature = signature or "",
				signature_hash = signature and hash_utils.hash(signature) or "00000000",
				start_line = block.start_line,
				end_line = block.end_line,
				language = block.lang,
				source = block.source,
				is_method = is_method,
				receiver = receiver,
			}

			-------------------------------------------------------------------
			-- 3. 返回轻量级结构上下文
			-------------------------------------------------------------------
			return {
				version = VERSION,
				code_block_info = info,
				target_file = file_path,
				target_line = lnum,
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
