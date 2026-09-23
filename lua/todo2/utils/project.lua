-- lua/todo2/utils/project.lua
-- 项目工具：项目名称与项目目录（统一多处重复的项目检测逻辑）

local M = {}

--- 获取当前项目名称（当前工作目录的 basename）
---@return string
function M.get_project_name()
	return vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
end

--- 获取项目 TODO 文件目录
---@param name string 项目名
---@return string
function M.get_project_dir(name)
	return vim.fn.expand("~/.todo-files/" .. name)
end

return M
