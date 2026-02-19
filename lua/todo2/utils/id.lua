-- lua/todo2/utils/id.lua
local M = {}
-- NOTE:ref:a589d4

--- 生成唯一ID
--- @return string 6位十六进制ID
function M.generate_id()
	return string.format("%06x", math.random(0, 0xFFFFFF))
end

--- 验证ID格式
--- @param id string
--- @return boolean
function M.is_valid(id)
	return id and id:match("^[a-f0-9]{6}$") ~= nil
end

return M
