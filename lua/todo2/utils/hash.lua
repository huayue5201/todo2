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

--- 生成一个简单的哈希值（备用方案，使用FNV-1a算法）
--- @param str string 输入字符串
--- @return string 8位十六进制哈希值
function M.hash_fnv1a(str)
	if not str or str == "" then
		return "00000000"
	end

	local hash = 0x811c9dc5 -- FNV offset basis

	for i = 1, #str do
		hash = bit.bxor(hash, string.byte(str, i))
		hash = to_u32(hash * 0x01000193) -- FNV prime
	end

	return string.format("%08x", hash)
end

--- 测试函数 - 验证哈希值是否正确生成
--- @param test_strings? table 可选的测试字符串列表
function M.test(test_strings)
	test_strings = test_strings
		or {
			"请求目标url",
			"把sheet表格数据写入文件",
			"伪造请求间隔时间",
			"解析最终数据",
			"这里可以叠加数据",
			"通过结构体动态传入配置参数来适配不同的json数据源",
			"cookie失效后好像会触发此处报错,影响错误定位",
			"需要根据响应类容进行正确错误处理,特别是cookie过期问题",
			"解析doc url,同上需要形成所有分页的url",
			"",
		}

	print("=== 哈希函数测试 ===")
	for _, s in ipairs(test_strings) do
		local h = M.hash(s)
		local h2 = M.hash_fnv1a(s)
		print(string.format("输入: %q", s))
		print(string.format("  MurmurHash3: %s", h))
		print(string.format("  FNV-1a:      %s", h2))
		print("---")
	end

	-- 验证之前出现问题的字符串
	print("\n=== 验证之前的问题字符串 ===")
	local problematic = {
		["请求目标url"] = "请求目标url",
		["把sheet表格数据写入文件"] = "把sheet表格数据写入文件",
		["伪造请求间隔时间"] = "伪造请求间隔时间",
	}

	for name, content in pairs(problematic) do
		local h = M.hash(content)
		print(string.format("%s: %s", name, h))
		-- 确保没有ffffffff前缀
		if h:match("^ffffffff") then
			print("  ⚠️  警告：仍包含ffffffff前缀！")
		end
	end
end

return M
