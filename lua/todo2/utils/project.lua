-- lua/todo2/utils/project.lua
-- 项目工具：项目名称与项目目录（统一多处重复的项目检测逻辑）

local M = {}

--- 获取当前项目名称（当前工作目录的 basename）
---@return string
function M.get_project_name()
	return vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
end

--- 获取项目注册表键：绝对路径 + 去尾斜杠 + 解析符号链接。
--- 注册表（~/.cache/nvim/todo2/projects.json）用它做键，避免「同名目录互相覆盖」。
---@param path string|nil 目录（默认 cwd）
---@return string|nil
function M.get_project_key(path)
	local raw = path
	if raw == nil or raw == "" then
		raw = vim.fn.getcwd()
	end
	if raw == nil or raw == "" then
		return nil
	end
	local p = vim.fn.fnamemodify(raw, ":p")
	if p == "" then
		return nil
	end
	p = p:gsub("(.)/+$", "%1")
	local uv = vim.uv or vim.loop
	local real = uv and uv.fs_realpath and uv.fs_realpath(p)
	if real and real ~= "" then
		p = real
	end
	return p
end

--- 路径的 basename（用于 TODO 文件名 / 旧式注册表键）
---@param path string
---@return string
function M.basename(path)
	return (path:gsub("(.)/+$", "%1"):match("([^/]+)$") or path)
end

--- 获取项目 TODO 文件目录
---@param name string 项目名
---@return string
function M.get_project_dir(name)
	return vim.fn.expand("~/.todo-files/" .. name)
end

return M
