-- lua/todo2/code_block/queries/init.lua
---@module 'todo2.code_block.queries'
---@brief 查询配置加载器
---
--- 负责加载和管理不同编程语言的 Treesitter 查询配置。
--- 支持从文件系统自动发现语言配置，并支持运行时动态添加。

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

--- 获取所有支持的语言列表
---
--- 通过扫描 runtimepath 中的所有语言配置文件来发现支持的语言。
--- 返回的语言列表包括：
--- - 已加载的语言配置（通过 get() 加载的）
--- - 存在配置文件但尚未加载的语言
---
--- 示例：
--- ```lua
--- local languages = code_block.get_supported_languages()
--- -- 返回: {"c", "go", "javascript", "lua", "python", "rust", "typescript"}
--- ```
---
---@return string[] 支持的语言名称列表，已排序且去重
function M.get_supported_languages()
	local langs = {}

	-- 扫描 runtimepath 中的所有语言配置文件
	-- 支持 Neovim 的 runtimepath 机制，包括插件目录和用户配置目录
	local pattern = "lua/todo2/code_block/queries/language/*.lua"
	local files = vim.api.nvim_get_runtime_file(pattern, true)

	for _, file in ipairs(files) do
		-- 从文件路径中提取语言名称
		-- 例如: /path/to/lua/todo2/code_block/queries/language/go.lua -> "go"
		local lang = file:match("language/([^/]+)%.lua$")
		if lang then
			table.insert(langs, lang)
		end
	end

	-- 去重并排序
	local seen = {}
	local result = {}
	for _, lang in ipairs(langs) do
		if not seen[lang] then
			seen[lang] = true
			table.insert(result, lang)
		end
	end
	table.sort(result)

	return result
end

--- 动态添加语言配置（用于运行时扩展）
---
--- 允许在运行时动态添加新的语言支持，无需创建配置文件。
---
--- 示例：
--- ```lua
--- code_block.add_language("kotlin", {
---     blocks = {
---         function_declaration = "function",
---         class_declaration = "class",
---     },
---     fields = {
---         name = "name",
---         parameters = "parameters",
---     },
---     format_signature = function(name, params)
---         return string.format("fun %s%s", name, params)
---     end,
--- })
--- ```
---
---@param ft string 文件类型，如 "kotlin", "swift"
---@param config CodeBlockLangConfig 语言配置
function M.add(ft, config)
	modules[ft] = config
end

return M
