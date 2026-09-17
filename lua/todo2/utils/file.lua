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

--- 判断路径是否为 TODO 文件
---@param path string
---@return boolean
function M.is_todo_file(path)
	if not path or path == "" then
		return false
	end
	return vim.endswith(path, ".todo.md") or vim.endswith(path, ".todo")
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

---读取文件行（优先从已加载的缓冲区读取，回退到磁盘）
---@param path string 文件路径
---@return string[]|nil 行列表，失败返回 nil
function M.read_lines_smart(path)
	if not path or path == "" then
		return nil
	end

	local bufnr = vim.fn.bufnr(path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if ok and lines then
		return lines
	end

	return nil
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


return M
