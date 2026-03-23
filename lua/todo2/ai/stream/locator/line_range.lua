-- lua/todo2/ai/stream/locator/line_range.lua
-- 增强版：支持签名哈希定位

local M = {}
local code_block = require("todo2.code_block")

function M.locate(protocol, ctx)
	-- 优先使用签名哈希定位（最可靠）
	if protocol.signature_hash then
		local bufnr = vim.fn.bufadd(ctx.path)
		vim.fn.bufload(bufnr)

		local blocks = code_block.get_all_blocks(bufnr)
		for _, block in ipairs(blocks) do
			if block.signature_hash == protocol.signature_hash then
				return {
					start_line = block.start_line,
					end_line = block.end_line,
					verified = true,
					method = "signature_hash",
				}
			end
		end
	end

	-- 降级：使用协议中的行号
	return {
		start_line = protocol.start_line,
		end_line = protocol.end_line,
		verified = false,
		method = "line_range",
	}
end

return M
