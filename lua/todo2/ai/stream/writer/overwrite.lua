-- lua/todo2/ai/stream/writer/overwrite.lua
-- 覆盖写入策略：支持缓冲区和文件写入

local M = {}
local validate = require("todo2.ai.validate")

---解析绝对路径
---@param path string
---@return string
local function resolve_path(path)
	if vim.startswith(path, "/") then
		return path
	end
	return vim.fn.getcwd() .. "/" .. path
end

---创建父目录
---@param path string
---@return boolean success
---@return string|nil error
local function ensure_parent_dir(path)
	local parent = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(parent) == 0 then
		local ok = pcall(vim.fn.mkdir, parent, "p")
		if not ok then
			return false, "无法创建目录: " .. parent
		end
	end
	return true, nil
end

---写入缓冲区
---@param bufnr number
---@param start_line integer
---@param end_line integer
---@param lines table
---@param opts table
---@return boolean success
---@return string|nil error
local function write_buffer(bufnr, start_line, end_line, lines, opts)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "无效的缓冲区"
	end

	local was_modifiable = vim.bo[bufnr].modifiable
	if not was_modifiable then
		vim.bo[bufnr].modifiable = true
	end

	local eventignore = vim.o.eventignore
	vim.o.eventignore = "all"

	local current_line_count = vim.api.nvim_buf_line_count(bufnr)
	local end_pos = end_line
	if end_pos > current_line_count then
		end_pos = current_line_count
	end

	vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_pos, false, lines)

	vim.o.eventignore = eventignore
	if not was_modifiable then
		vim.bo[bufnr].modifiable = false
	end

	-- 高亮反馈
	local ns = vim.api.nvim_create_namespace("dwight_replace_" .. start_line .. "_" .. os.time())
	local new_end = start_line - 1 + #lines
	for i = start_line - 1, math.min(new_end - 1, vim.api.nvim_buf_line_count(bufnr) - 1) do
		pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, "DwightReplace", i, 0, -1)
	end
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		end
	end, 3000)

	return true, nil
end

---写入文件
---@param path string
---@param lines table
---@param opts table
---@return boolean success
---@return string|nil error
local function write_file(path, lines, opts)
	-- 解析绝对路径
	local abs_path = resolve_path(path)

	-- 创建父目录
	local ok, err = ensure_parent_dir(abs_path)
	if not ok then
		return false, err
	end

	-- 语法验证（可选）
	if opts.validate then
		local content = table.concat(lines, "\n")
		local lang = vim.filetype.match({ filename = abs_path }) or ""
		local ok, err = validate.syntax_check(content, lang, abs_path)
		if not ok then
			return false, "语法验证失败: " .. (err or "unknown")
		end
	end

	-- 写入文件
	local content = table.concat(lines, "\n")
	local f = io.open(abs_path, "w")
	if not f then
		return false, "无法打开文件: " .. abs_path
	end
	f:write(content)
	f:close()

	-- 刷新 Neovim 缓冲区
	local bufnr = vim.fn.bufnr(abs_path)
	if bufnr ~= -1 then
		vim.cmd("checktime " .. vim.fn.fnameescape(abs_path))
	end

	return true, nil
end

---写入主入口
---@param mode string "overwrite"
---@param bufnr number
---@param range table { start_line, end_line }
---@param lines table
---@param opts table { validate = boolean, on_progress = function }
---@return boolean success
---@return string|nil error
function M.write(mode, bufnr, range, lines, opts)
	opts = opts or {}

	if not bufnr or bufnr == -1 then
		-- 缓冲区无效，尝试写入文件
		local path = vim.api.nvim_buf_get_name(bufnr) or ""
		if path and path ~= "" then
			return write_file(path, lines, opts)
		end
		return false, "无效的缓冲区且无法获取文件路径"
	end

	-- 验证缓冲区是否有效
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "缓冲区已关闭"
	end

	-- 写入缓冲区
	return write_buffer(bufnr, range.start_line, range.end_line, lines, opts)
end

return M
