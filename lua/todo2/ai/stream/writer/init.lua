local M = {}

local strategies = {
	overwrite = require("todo2.ai.stream.writer.overwrite"),
	insert = require("todo2.ai.stream.writer.insert"),
}

function M.write(mode, bufnr, range, lines)
	local s = strategies[mode]
	if not s then
		return nil, "未知写入模式: " .. tostring(mode)
	end
	return s.write(bufnr, range, lines)
end

return M
