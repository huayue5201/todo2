-- lua/todo2/store/utils.lua
--- @module todo2.store.utils

local M = {}

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

--- 格式化时间戳为 YYYY-MM-DD HH:MM:SS
--- @param timestamp number
--- @return string
function M.format_time(timestamp)
	return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

--- 计算相对路径（相对于当前工作目录）
--- @param path string
--- @return string
function M.relative_path(path)
	local relative = vim.fn.fnamemodify(path, ":.")
	return relative
end

---------------------------------------------------------------------
-- ✅ 新增：生成唯一 6 位十六进制 ID
-- 与 link/utils.lua 中的 generate_id 保持完全一致
---------------------------------------------------------------------
--- 生成唯一 ID
--- @return string 6 位十六进制随机数（例如 "a3f1c2"）
function M.generate_id()
	return string.format("%06x", math.random(0, 0xFFFFFF))
end

return M
