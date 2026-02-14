-- lua/todo2/utils/hash.lua
--- @module todo2.utils.hash
--- @brief 简单的哈希函数模块（用于快照校验）

local M = {}

--- 简单的字符串哈希函数（djb2 算法）
--- @param str string 输入字符串
--- @return string 8位十六进制哈希值
function M.hash(str)
	if not str or str == "" then
		return "00000000"
	end

	local hash = 5381 -- djb2 初始值

	for i = 1, #str do
		local c = string.byte(str, i)
		hash = (hash * 33) + c -- djb2: hash * 33 + c
		hash = hash % 4294967296 -- 保持在 32 位整数范围内
	end

	return string.format("%08x", hash)
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
