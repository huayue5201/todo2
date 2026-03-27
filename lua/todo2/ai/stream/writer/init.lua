-- lua/todo2/ai/stream/writer/init.lua
local M = {}

local strategies = {
	overwrite = require("todo2.ai.stream.writer.overwrite"),
	insert = require("todo2.ai.stream.writer.insert"),
}

---写入主入口
---@param mode string "overwrite" | "insert"
---@param bufnr number
---@param range table { start_line, end_line }
---@param lines table
---@param opts table { validate = boolean, create_dirs = boolean, on_progress = function }
---@return boolean success
---@return string|nil error
function M.write(mode, bufnr, range, lines, opts)
	opts = opts or {}
	-- 默认开启验证
	opts.validate = opts.validate ~= false
	-- 默认创建目录
	opts.create_dirs = opts.create_dirs ~= false

	local s = strategies[mode]
	if not s then
		return false, "未知写入模式: " .. tostring(mode)
	end
	return s.write(mode, bufnr, range, lines, opts)
end

return M
