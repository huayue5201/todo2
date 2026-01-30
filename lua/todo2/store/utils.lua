-- lua/todo2/store/utils.lua
--- @module todo2.store.utils

local M = {}

--- 生成唯一ID
--- @return string
function M.generate_id()
	local time = os.time()
	local random = math.random(1000, 9999)
	return string.format("%s_%s", time, random)
end

--- 检查文件是否存在
--- @param path string
--- @return boolean
function M.file_exists(path)
	return vim.fn.filereadable(path) == 1
end

--- 安全的字符串截取
--- @param str string
--- @param max_len number
--- @return string
function M.truncate(str, max_len)
	if not str or #str <= max_len then
		return str or ""
	end
	return str:sub(1, max_len - 3) .. "..."
end

--- 深度复制表
--- @param tbl table
--- @return table
function M.deep_copy(tbl)
	if type(tbl) ~= "table" then
		return tbl
	end
	local result = {}
	for k, v in pairs(tbl) do
		result[k] = M.deep_copy(v)
	end
	return result
end

--- 格式化时间戳
--- @param timestamp number
--- @return string
function M.format_time(timestamp)
	return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

--- 计算相对路径
--- @param path string
--- @return string
function M.relative_path(path)
	local cwd = vim.fn.getcwd()
	local relative = vim.fn.fnamemodify(path, ":.")
	return relative
end

return M
