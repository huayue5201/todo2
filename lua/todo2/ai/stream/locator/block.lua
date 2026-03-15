local id = require("todo2.utils.id") -- 你未来的语义 ID 模块

local M = {}

function M.locate(protocol, ctx)
	local block = id.get_block(protocol.block_id)
	if not block then
		return nil, "找不到 block: " .. protocol.block_id
	end

	return {
		start_line = block.start_line,
		end_line = block.end_line,
	}
end

return M
