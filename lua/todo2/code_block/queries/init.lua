-- lua/todo2/code_block/queries/init.lua
---@module 'todo2.code_block.queries'
---@brief 查询配置加载器
---
--- 负责按文件类型加载 Treesitter 查询配置。

local M = {}
local modules = {}

---@class CodeBlockLangConfig
---@field blocks table<string, string>  节点类型到代码块类型的映射，如 { function_declaration = "function" }
---@field fields table<string, string>  节点字段映射，如 { name = "name", parameters = "parameters" }
---@field format_signature? fun(name:string, params:string, return_type?:string, receiver?:string, is_async?:boolean):string  签名格式化函数

--- 加载语言模块
---@param ft string 文件类型，如 "lua", "python", "go"
---@return CodeBlockLangConfig|nil 语言配置，如果加载失败返回 nil
local function load_lang(ft)
	if modules[ft] then
		return modules[ft]
	end

	local ok, mod = pcall(require, "todo2.code_block.queries.language." .. ft)
	if ok then
		modules[ft] = mod
		return mod
	end

	return nil
end

--- 获取语言配置
---@param ft string 文件类型，如 "lua", "python", "go"
---@return CodeBlockLangConfig|nil 语言配置，如果语言不支持或加载失败返回 nil
function M.get(ft)
	return load_lang(ft)
end

return M
