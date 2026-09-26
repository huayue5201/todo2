-- lua/todo2/utils/hash.lua
--- @module todo2.utils.hash
--- @brief 改进的哈希函数模块（使用 bit 模块，修复32位溢出问题）

local M = {}
local bit = require("bit") -- Neovim 内置的位运算模块

--- 32位无符号整数截断辅助函数
--- @param x number
--- @return number
local function to_u32(x)
	return bit.band(x, 0xffffffff)
end

--- 32位无符号整数左旋转
--- @param x number 输入值
--- @param r number 旋转位数
--- @return number
local function rotl(x, r)
	x = to_u32(x)
	return bit.bor(bit.lshift(x, r), bit.rshift(x, 32 - r))
end

--- MurmurHash3 的最终混合函数（32位安全版）
--- @param h number
--- @return number
local function fmix(h)
	h = to_u32(h)
	h = bit.bxor(h, bit.rshift(h, 16))
	h = to_u32(h * 0x85ebca6b)
	h = bit.bxor(h, bit.rshift(h, 13))
	h = to_u32(h * 0xc2b2ae35)
	h = bit.bxor(h, bit.rshift(h, 16))
	return h
end

--- MurmurHash3 风格的字符串哈希（32位安全版）
--- @param str string 输入字符串
--- @return string 8位十六进制哈希值
function M.hash(str)
	if not str or str == "" then
		return "00000000"
	end

	local len = #str
	local h1 = 0x971e137b -- seed
	local c1 = 0xcc9e2d51
	local c2 = 0x1b873593

	local i = 1
	-- 处理每4个字节的块
	while i + 3 <= len do
		-- 安全地组合4个字节为32位整数
		local k1 = 0
		k1 = bit.bor(k1, string.byte(str, i))
		k1 = bit.bor(k1, bit.lshift(string.byte(str, i + 1) or 0, 8))
		k1 = bit.bor(k1, bit.lshift(string.byte(str, i + 2) or 0, 16))
		k1 = bit.bor(k1, bit.lshift(string.byte(str, i + 3) or 0, 24))
		k1 = to_u32(k1)

		-- k1 = k1 * c1
		k1 = to_u32(k1 * c1)
		k1 = rotl(k1, 15)
		k1 = to_u32(k1 * c2)

		h1 = bit.bxor(h1, k1)
		h1 = rotl(h1, 13)
		-- h1 = h1 * 5 + 0xe6546b64 (避免直接乘法溢出)
		h1 = to_u32(h1 * 5)
		h1 = to_u32(h1 + 0xe6546b64)

		i = i + 4
	end

	-- 处理剩余字节 (1-3个字节)
	local k1 = 0
	local remaining = len - i + 1

	if remaining == 3 then
		k1 = bit.bor(k1, bit.lshift(string.byte(str, i + 2) or 0, 16))
	end
	if remaining >= 2 then
		k1 = bit.bor(k1, bit.lshift(string.byte(str, i + 1) or 0, 8))
	end
	if remaining >= 1 then
		k1 = bit.bor(k1, string.byte(str, i) or 0)
		k1 = to_u32(k1)

		k1 = to_u32(k1 * c1)
		k1 = rotl(k1, 15)
		k1 = to_u32(k1 * c2)

		h1 = bit.bxor(h1, k1)
	end

	-- 混合长度和最终处理
	h1 = bit.bxor(h1, len)
	h1 = fmix(h1)

	return string.format("%08x", h1)
end

return M
