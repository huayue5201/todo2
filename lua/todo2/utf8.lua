-- lua/todo2/utf8.lua
local U = {}

function U.sub(str, max_chars)
	if not str then
		return ""
	end
	local cur = 0
	local i = 1
	local len = #str

	while i <= len do
		cur = cur + 1
		if cur > max_chars then
			return str:sub(1, i - 1)
		end

		local c = str:byte(i)
		if c < 0x80 then
			i = i + 1
		elseif c < 0xE0 then
			i = i + 2
		elseif c < 0xF0 then
			i = i + 3
		else
			i = i + 4
		end
	end

	return str
end

return U
