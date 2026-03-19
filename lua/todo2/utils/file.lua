-- lua/todo2/utils/file.lua
-- 文件工具模块：提供统一的文件路径处理和读写功能
---@module "todo2.utils.file"

local M = {}

---------------------------------------------------------------------
-- 路径规范化
---------------------------------------------------------------------

---规范化路径为绝对路径
---@param path string 文件路径
---@return string 规范化后的绝对路径
function M.normalize_path(path)
	if not path or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":p")
end

---获取文件所在目录
---@param path string 文件路径
---@return string 目录路径
function M.dirname(path)
	if not path or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":h")
end

---获取文件名（不含路径）
---@param path string 文件路径
---@return string 文件名
function M.basename(path)
	if not path or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":t")
end

---获取文件扩展名
---@param path string 文件路径
---@return string 扩展名（包含点，如 ".lua"）
function M.extension(path)
	if not path or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":e")
end

---判断是否为TODO文件
---@param path string 文件路径
---@return boolean
function M.is_todo_file(path)
	if not path or path == "" then
		return false
	end
	return path:match("%.todo%.md$") or path:match("%.todo$")
end

---判断是否为代码文件
---@param path string 文件路径
---@return boolean
function M.is_code_file(path)
	return path ~= "" and not M.is_todo_file(path)
end

---------------------------------------------------------------------
-- 文件读写
---------------------------------------------------------------------

---安全读取文件内容
---@param path string 文件路径
---@return string[] 行列表，失败返回空表
function M.read_lines(path)
	if not path or path == "" then
		return {}
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	return ok and lines or {}
end

---安全写入文件内容
---@param path string 文件路径
---@param lines string[] 行列表
---@return boolean 是否成功
function M.write_lines(path, lines)
	if not path or path == "" then
		return false
	end
	local ok, _ = pcall(vim.fn.writefile, lines, path)
	return ok
end

---检查文件是否存在
---@param path string 文件路径
---@return boolean
function M.exists(path)
	if not path or path == "" then
		return false
	end
	return vim.fn.filereadable(path) == 1
end

---获取文件修改时间
---@param path string 文件路径
---@return number|nil 时间戳（秒），失败返回nil
function M.mtime(path)
	if not path or path == "" then
		return nil
	end
	local stat = vim.loop.fs_stat(path)
	return stat and stat.mtime and stat.mtime.sec or nil
end

---------------------------------------------------------------------
-- 缓冲区操作
---------------------------------------------------------------------

---获取缓冲区文件路径
---@param bufnr number 缓冲区号
---@return string 文件路径，无效返回空字符串
function M.buf_path(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return ""
	end
	return vim.api.nvim_buf_get_name(bufnr)
end

---检查缓冲区是否有效
---@param bufnr number 缓冲区号
---@return boolean
function M.is_valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

---获取缓冲区行数
---@param bufnr number 缓冲区号
---@return number
function M.buf_line_count(bufnr)
	if not M.is_valid_buf(bufnr) then
		return 0
	end
	return vim.api.nvim_buf_line_count(bufnr)
end

---安全获取缓冲区行内容
---@param bufnr number 缓冲区号
---@param line_num number 行号（1-based）
---@return string 行内容，无效返回空字符串
function M.get_buf_line(bufnr, line_num)
	if not M.is_valid_buf(bufnr) then
		return ""
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)
	return lines[1] or ""
end

---获取缓冲区所有行
---@param bufnr number 缓冲区号
---@return string[]
function M.get_buf_lines(bufnr)
	if not M.is_valid_buf(bufnr) then
		return {}
	end
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---检查行号是否有效
---@param bufnr number 缓冲区号
---@param line_num number 行号（1-based）
---@return boolean
function M.is_valid_line(bufnr, line_num)
	if not M.is_valid_buf(bufnr) then
		return false
	end
	local total = vim.api.nvim_buf_line_count(bufnr)
	return line_num >= 1 and line_num <= total
end

return M
