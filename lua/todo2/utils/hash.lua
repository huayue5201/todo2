-- lua/todo2/utils/hash.lua
--- @module todo2.utils.hash
--- @brief 改进的哈希函数模块（使用 bit 模块）

local M = {}
local bit = require("bit") -- Neovim 内置的位运算模块

--- MurmurHash3 风格的字符串哈希
--- @param str string 输入字符串
--- @return string 8位十六进制哈希值
function M.hash(str)
	if not str or str == "" then
		return "00000000"
	end

	local function rotl(x, r)
		return bit.bor(bit.lshift(x, r), bit.rshift(x, 32 - r))
	end

	local function fmix(h)
		h = bit.bxor(h, bit.rshift(h, 16))
		h = h * 0x85ebca6b
		h = bit.bxor(h, bit.rshift(h, 13))
		h = h * 0xc2b2ae35
		h = bit.bxor(h, bit.rshift(h, 16))
		return h
	end

	local len = #str
	local h1 = 0x971e137b -- seed
	local c1 = 0xcc9e2d51
	local c2 = 0x1b873593

	local i = 1
	while i + 3 <= len do
		local k1 = string.byte(str, i) or 0
		k1 = k1 + (bit.lshift(string.byte(str, i + 1) or 0, 8))
		k1 = k1 + (bit.lshift(string.byte(str, i + 2) or 0, 16))
		k1 = k1 + (bit.lshift(string.byte(str, i + 3) or 0, 24))

		k1 = k1 * c1
		k1 = rotl(k1, 15)
		k1 = k1 * c2

		h1 = bit.bxor(h1, k1)
		h1 = rotl(h1, 13)
		h1 = h1 * 5 + 0xe6546b64

		i = i + 4
	end

	-- 处理剩余字节
	local k1 = 0
	local remaining = len - i + 1
	if remaining == 3 then
		k1 = bit.bxor(k1, bit.lshift(string.byte(str, i + 2) or 0, 16))
	end
	if remaining >= 2 then
		k1 = bit.bxor(k1, bit.lshift(string.byte(str, i + 1) or 0, 8))
	end
	if remaining >= 1 then
		k1 = bit.bxor(k1, string.byte(str, i) or 0)
		k1 = k1 * c1
		k1 = rotl(k1, 15)
		k1 = k1 * c2
		h1 = bit.bxor(h1, k1)
	end

	h1 = bit.bxor(h1, len)
	h1 = fmix(h1)

	return string.format("%08x", h1)
end

--- 计算文件的哈希值
--- @param filepath string 文件路径
--- @return string|nil 文件哈希值，文件不存在返回 nil
function M.hash_file(filepath)
	if vim.fn.filereadable(filepath) ~= 1 then
		return nil
	end

	local lines = vim.fn.readfile(filepath)
	local content = table.concat(lines, "\n")
	return M.hash(content)
end

--- 计算多个字符串组合的哈希值
--- @param ... string 可变参数，多个字符串
--- @return string 组合哈希值
function M.combine(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local arg = select(i, ...)
		table.insert(parts, tostring(arg))
	end
	return M.hash(table.concat(parts, ":"))
end

--- 验证字符串与哈希值是否匹配
--- @param str string 原始字符串
--- @param expected_hash string 期望的哈希值
--- @return boolean
function M.verify(str, expected_hash)
	return M.hash(str) == expected_hash
end

return M
