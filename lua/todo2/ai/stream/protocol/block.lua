local M = {}

function M.match(chunk)
	local id = chunk:match("REPLACEBLOCKid=([%w_]+):?")
	if id then
		return {
			type = "replace",
			mode = "block",
			block_id = id,
		}
	end
	return nil
end

return M
