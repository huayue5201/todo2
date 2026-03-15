local M = {}

local strategies = {
	require("todo2.ai.stream.protocol.line_range"),
	require("todo2.ai.stream.protocol.block"),
}

function M.parse(chunk)
	for _, s in ipairs(strategies) do
		local result = s.match(chunk)
		if result then
			return result
		end
	end
	return nil
end

return M
