-- lua/todo2/utils/file.lua
-- 文件工具模块：提供统一的文件路径处理和读写功能
---@module "todo2.utils.file"

local M = {}

local config = require("todo2.config")

---------------------------------------------------------------------
-- 路径规范化
---------------------------------------------------------------------

-- 路径规范化缓存：同一路径无需反复走文件系统
local normalize_cache = {}

---规范化路径：绝对路径 + 解析符号链接。
---必须与 Neovim 的 buffer 名保持一致（`nvim_buf_get_name` 给出的是真实路径），
---否则索引键与 buffer 路径对不上，代码标记的行号追踪会静默失效。
---@param path string|nil 文件路径
---@return string 规范化后的绝对路径
function M.normalize_path(path)
	if not path or path == "" then
		return ""
	end

	local cached = normalize_cache[path]
	if cached then
		return cached
	end

	local abs = vim.fn.fnamemodify(path, ":p")
	local real = (vim.uv or vim.loop).fs_realpath(abs)
	if real then
		normalize_cache[path] = real
		return real
	end

	-- 文件尚不存在：不缓存，等它出现后再解析
	return abs
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

--- 判断路径是否为 TODO 文件（扩展名/文件名由配置决定）
---@param path string
---@return boolean
function M.is_todo_file(path)
	if not path or path == "" then
		return false
	end

	local cfg = config.get("todo_files")
	local extensions = cfg.extensions
	local filenames = cfg.filenames

	for _, ext in ipairs(extensions) do
		if vim.endswith(path, ext) then
			return true
		end
	end

	local base = M.basename(path)
	for _, name in ipairs(filenames) do
		if base == name then
			return true
		end
	end

	return false
end

--- 获取 TODO 文件的 glob 模式列表
---@return string[]
function M.todo_globs()
	local cfg = config.get("todo_files")
	return cfg.globs
end

--- 获取 TODO 文件的 autocmd 用 glob 模式串（逗号分隔）
---@return string
function M.todo_autocmd_pattern()
	return table.concat(M.todo_globs(), ",")
end

--- 获取新建 TODO 文件默认后缀
---@return string
function M.todo_default_ext()
	local cfg = config.get("todo_files")
	return cfg.default_ext
end

--- 去除文件名尾部的 TODO 后缀（用于重命名时预填名称）
---@param filename string
---@return string
function M.todo_stem(filename)
	if not filename or filename == "" then
		return ""
	end

	local cfg = config.get("todo_files")
	local extensions = cfg.extensions
	local filenames = cfg.filenames

	for _, ext in ipairs(extensions) do
		if vim.endswith(filename, ext) then
			return filename:sub(1, -#ext - 1)
		end
	end

	local base = M.basename(filename)
	for _, name in ipairs(filenames) do
		if base == name then
			return filename:sub(1, -#name - 1)
		end
	end

	return filename
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
