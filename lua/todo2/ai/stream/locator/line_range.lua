-- lua/todo2/ai/stream/locator/line_range.lua
-- 增强版：支持签名哈希定位，失败时降级到行号

local M = {}
local code_block = require("todo2.code_block")

---通过签名哈希查找代码块
---@param bufnr integer
---@param signature_hash string
---@return table|nil
local function locate_by_hash(bufnr, signature_hash)
	if not signature_hash or signature_hash == "00000000" then
		return nil
	end

	local blocks = code_block.get_all_blocks(bufnr)
	for _, block in ipairs(blocks) do
		if block.signature_hash == signature_hash then
			return {
				start_line = block.start_line,
				end_line = block.end_line,
				verified = true,
				method = "signature_hash",
				block = block,
			}
		end
	end
	return nil
end

---通过内容相似度查找（兜底）
---@param bufnr integer
---@param original_signature string
---@return table|nil
local function locate_by_signature_text(bufnr, original_signature)
	if not original_signature or original_signature == "" then
		return nil
	end

	local blocks = code_block.get_all_blocks(bufnr)
	local best_match = nil
	local best_score = 0

	for _, block in ipairs(blocks) do
		local block_sig = block.signature or ""
		-- 简单的相似度计算：关键词匹配
		local score = 0
		for word in original_signature:lower():gmatch("%w+") do
			if block_sig:lower():find(word, 1, true) then
				score = score + 1
			end
		end
		if score > best_score then
			best_score = score
			best_match = block
		end
	end

	if best_match and best_score >= 2 then
		return {
			start_line = best_match.start_line,
			end_line = best_match.end_line,
			verified = false,
			method = "signature_text_fallback",
			similarity_score = best_score,
			block = best_match,
		}
	end
	return nil
end

---定位代码范围
---@param protocol table { start_line, end_line, signature_hash, signature }
---@param ctx table { path, start_line, end_line }
---@return table|nil range
---@return string|nil error
function M.locate(protocol, ctx)
	if not protocol or not ctx then
		return nil, "缺少协议或上下文"
	end

	local bufnr = vim.fn.bufnr(ctx.path)
	if bufnr == -1 then
		return nil, "无法打开文件: " .. ctx.path
	end

	-- 策略1: 签名哈希定位（最可靠）
	local result = locate_by_hash(bufnr, protocol.signature_hash)
	if result then
		return result, nil
	end

	-- 策略2: 签名文本定位（降级）
	result = locate_by_signature_text(bufnr, protocol.signature)
	if result then
		return result, nil
	end

	-- 策略3: 行号定位（最终降级）
	if protocol.start_line and protocol.end_line then
		return {
			start_line = protocol.start_line,
			end_line = protocol.end_line,
			verified = false,
			method = "line_range",
		},
			nil
	end

	-- 策略4: 使用上下文中的行号（极端降级）
	if ctx.start_line and ctx.end_line then
		return {
			start_line = ctx.start_line,
			end_line = ctx.end_line,
			verified = false,
			method = "context_fallback",
		},
			nil
	end

	return nil, "无法定位代码范围"
end

return M
