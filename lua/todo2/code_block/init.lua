-- lua/todo2/code_block/init.lua
-- 代码块采集模块入口
--
-- 该模块提供了从代码文件中提取代码块（函数、类、方法等）的功能。
-- 支持多种后端：Treesitter（优先）、LSP（降级）、缩进检测（最终降级）。
--
-- 使用示例：
-- ```lua
-- local code_block = require("todo2.code_block")
--
-- -- 初始化（可选）
-- code_block.setup({
--     use_treesitter = true,
--     use_lsp = true,
--     debug = false,
-- })
--
-- -- 获取光标所在的代码块
-- local bufnr = 0
-- local lnum = vim.api.nvim_win_get_cursor(0)[1]
-- local block = code_block.get_block_at_line(bufnr, lnum)
-- if block then
--     print("代码块类型: " .. block.type)
--     print("名称: " .. (block.name or "unnamed"))
--     print("签名: " .. (block.signature or ""))
-- end
--
-- -- 获取文件中所有代码块
-- local all_blocks = code_block.get_all_blocks(bufnr)
-- for _, block in ipairs(all_blocks) do
--     print(string.format("%s: %s (%d-%d)",
--         block.type, block.name or "unnamed",
--         block.start_line, block.end_line))
-- end
-- ```

local Engine = require("todo2.code_block.core.engine")
local Queries = require("todo2.code_block.queries")

local M = {}

-- 导出查询配置（供外部扩展）
M.queries = Queries

-- ============================================================================
-- 核心 API
-- ============================================================================

--- 获取指定行的代码块
---
--- 根据优先级顺序（Treesitter > LSP > 缩进检测）尝试获取代码块。
--- 会优先使用 Treesitter，如果不可用则降级到 LSP，最后使用缩进检测。
---
--- 使用示例：
--- ```lua
--- local bufnr = 0  -- 当前缓冲区
--- local lnum = vim.api.nvim_win_get_cursor(0)[1]  -- 当前行
--- local block = code_block.get_block_at_line(bufnr, lnum)
--- if block then
---     print(string.format("代码块: %s (%d-%d)", block.type, block.start_line, block.end_line))
--- end
--- ```
---
---@param bufnr integer 缓冲区编号
---@param lnum integer 行号（1-indexed）
---@return CodeBlock|nil 代码块信息，如果未找到返回 nil
M.get_block_at_line = Engine.get_block_at_line

--- 获取文件中的所有代码块
---
--- 返回文件中所有可识别的代码块（函数、类、方法等）。
--- 结果会被缓存以提高性能，缓存键基于文件的 changedtick。
---
--- 使用示例：
--- ```lua
--- local blocks = code_block.get_all_blocks(0)
--- for _, block in ipairs(blocks) do
---     print(string.format("%s: %s [%d-%d]",
---         block.type, block.name or "unnamed",
---         block.start_line, block.end_line))
--- end
--- ```
---
---@param bufnr integer 缓冲区编号
---@return CodeBlock[] 代码块列表，如果没有找到返回空表
M.get_all_blocks = Engine.get_all_blocks

--- 获取代码块的完整文本内容
---
--- 返回指定代码块的完整源代码文本，包含缩进和格式。
---
--- 使用示例：
--- ```lua
--- local block = code_block.get_block_at_line(0, 10)
--- if block then
---     local text = code_block.get_block_text(0, block)
---     print("代码块内容:\n" .. text)
--- end
--- ```
---
---@param bufnr integer 缓冲区编号
---@param block CodeBlock 代码块对象
---@return string|nil 代码块文本内容，如果获取失败返回 nil
M.get_block_text = Engine.get_block_text

--- 获取代码块的签名
---
--- 返回代码块的签名行（通常是第一行），例如函数声明行。
--- 优先使用 block.signature，否则从 block.text 或 block.first_line 提取。
---
--- 使用示例：
--- ```lua
--- local block = code_block.get_block_at_line(0, 10)
--- if block then
---     local signature = code_block.get_block_signature(block)
---     print("签名: " .. signature)
--- end
--- ```
---
---@param block CodeBlock 代码块对象
---@return string|nil 代码块签名，如果无法获取返回 nil
M.get_block_signature = Engine.get_block_signature

--- 获取代码块的名称
---
--- 从代码块中提取名称（函数名、类名等）。
--- 如果 block.name 已存在则直接返回，否则从签名中提取。
---
--- 使用示例：
--- ```lua
--- local block = code_block.get_block_at_line(0, 10)
--- if block then
---     local name = code_block.get_block_name(block)
---     print("代码块名称: " .. (name or "unnamed"))
--- end
--- ```
---
---@param block CodeBlock 代码块对象
---@return string|nil 代码块名称，如果无法提取返回 nil
M.get_block_name = Engine.get_block_name

--- 获取代码块的类型
---
--- 返回代码块类型，如 "function", "class", "method", "struct" 等。
---
--- 使用示例：
--- ```lua
--- local block = code_block.get_block_at_line(0, 10)
--- if block then
---     local type = code_block.get_block_type(block)
---     print("代码块类型: " .. type)
--- end
--- ```
---
---@param block CodeBlock 代码块对象
---@return string|nil 代码块类型，如 "function", "class"，如果无法获取返回 nil
M.get_block_type = Engine.get_block_type

--- 判断代码块是否为方法
---
--- 检查代码块是否是一个方法（属于类或结构体的函数）。
---
--- 使用示例：
--- ```lua
--- local block = code_block.get_block_at_line(0, 10)
--- if code_block.is_method(block) then
---     print("这是一个方法")
---     local receiver = code_block.get_receiver(block)
---     if receiver then
---         print("接收者: " .. receiver)
---     end
--- end
--- ```
---
---@param block CodeBlock 代码块对象
---@return boolean true 如果是方法，否则 false
M.is_method = Engine.is_method

--- 获取方法的接收者
---
--- 如果代码块是方法，返回接收者类型（如 Go 的 (r *Receiver)）。
---
--- 使用示例：
--- ```lua
--- local block = code_block.get_block_at_line(0, 10)
--- if code_block.is_method(block) then
---     local receiver = code_block.get_receiver(block)
---     if receiver then
---         print("接收者: " .. receiver)
---     end
--- end
--- ```
---
---@param block CodeBlock 代码块对象
---@return string|nil 接收者字符串，如果不是方法或无法获取返回 nil
M.get_receiver = Engine.get_receiver

-- ============================================================================
-- 缓存管理
-- ============================================================================

--- 清空缓存
---
--- 清除代码块和符号的缓存。如果指定 bufnr，只清除该缓冲区的缓存；
--- 如果不指定，清除所有缓存。
---
--- 使用场景：
--- - 文件内容被外部工具修改后
--- - 调试时需要强制重新解析
--- - 添加新语言配置后需要刷新缓存
---
--- 使用示例：
--- ```lua
--- -- 清除所有缓存
--- code_block.clear_cache()
---
--- -- 只清除当前缓冲区的缓存
--- code_block.clear_cache(0)
--- ```
---
---@param bufnr? integer 缓冲区编号，可选。如果提供，只清除该缓冲区的缓存
M.clear_cache = Engine.clear_cache

-- ============================================================================
-- 配置管理
-- ============================================================================

--- 初始化模块配置
---
--- 设置模块的运行参数。应该在插件启动时调用。
---
--- 配置选项：
--- ```lua
--- {
---     use_treesitter = true,      -- 是否启用 Treesitter 后端（默认 true）
---     use_lsp = true,             -- 是否启用 LSP 后端（默认 true）
---     use_indent_fallback = true, -- 是否启用缩进检测降级（默认 true）
---     debug = false,              -- 是否输出调试日志（默认 false）
---     cache_ttl = 60,             -- 缓存过期时间（秒，默认 60）
---     cache_max_items = 200,      -- 最大缓存项数（默认 200）
--- }
--- ```
---
--- 使用示例：
--- ```lua
--- -- 默认配置
--- code_block.setup()
---
--- -- 自定义配置
--- code_block.setup({
---     use_treesitter = true,
---     use_lsp = true,
---     debug = vim.g.debug_mode or false,
---     cache_ttl = 30,
--- })
---
--- -- 禁用 LSP，只使用 Treesitter
--- code_block.setup({
---     use_treesitter = true,
---     use_lsp = false,
---     use_indent_fallback = true,
--- })
--- ```
---
---@param opts? table 配置选项，所有字段都是可选的
M.setup = Engine.setup

--- 获取当前配置
---
--- 返回当前模块的配置快照，是一个深拷贝的副本，
--- 修改返回值不会影响实际配置。
---
--- 使用示例：
--- ```lua
--- local config = code_block.get_config()
--- print("缓存 TTL: " .. config.cache_ttl)
--- print("Treesitter 启用: " .. tostring(config.use_treesitter))
--- ```
---
---@return table 当前配置的深拷贝
M.get_config = Engine.get_config

-- ============================================================================
-- 语言扩展 API
-- ============================================================================

--- 添加新语言支持
---
--- 动态注册新的编程语言支持，无需创建配置文件。
--- 该函数会覆盖已存在的语言配置。
---
--- 语言配置结构：
--- ```lua
--- {
---     -- 节点类型到代码块类型的映射
---     blocks = {
---         function_declaration = "function",
---         class_declaration = "class",
---         method_definition = "method",
---         -- 可添加更多映射
---     },
---
---     -- 字段名称映射（用于提取名称、参数等信息）
---     fields = {
---         name = "name",           -- 名称字段名
---         parameters = "parameters", -- 参数字段名
---         return_type = "type",    -- 返回值字段名（可选）
---         receiver = "receiver",   -- 接收者字段名（用于方法，可选）
---     },
---
---     -- 签名格式化函数（可选）
---     -- @param name string 函数/类名
---     -- @param params string 参数字符串
---     -- @param return_type string|nil 返回值类型
---     -- @param receiver string|nil 接收者（仅方法）
---     -- @param is_async boolean|nil 是否异步函数
---     -- @return string 格式化后的签名
---     format_signature = function(name, params, return_type, receiver, is_async)
---         if receiver then
---             return string.format("func (%s) %s%s", receiver, name, params)
---         end
---         return string.format("func %s%s", name, params)
---     end,
--- }
--- ```
---
--- 使用示例：
--- ```lua
--- -- 添加 Kotlin 语言支持
--- code_block.add_language("kotlin", {
---     blocks = {
---         function_declaration = "function",
---         class_declaration = "class",
---     },
---     fields = {
---         name = "name",
---         parameters = "value_parameters",
---     },
---     format_signature = function(name, params)
---         return string.format("fun %s%s", name, params)
---     end,
--- })
---
--- -- 添加 Swift 语言支持
--- code_block.add_language("swift", {
---     blocks = {
---         function_declaration = "function",
---         class_declaration = "class",
---         struct_declaration = "struct",
---         enum_declaration = "enum",
---     },
---     fields = {
---         name = "name",
---         parameters = "parameter_clause",
---     },
--- })
--- ```
---
---@param ft string 文件类型，如 "kotlin", "swift", "ruby"
---@param lang_config table 语言配置，包含 blocks 和 fields 字段
function M.add_language(ft, lang_config)
	Queries.add(ft, lang_config)
end

--- 获取所有支持的语言列表
---
--- 通过扫描 Neovim 的 runtimepath 返回所有已配置的语言。
--- 返回的语言列表包括：
--- - 通过 add_language() 动态添加的语言
--- - 通过配置文件存在但尚未加载的语言
---
--- 使用示例：
--- ```lua
--- -- 获取所有支持的语言
--- local languages = code_block.get_supported_languages()
--- print("支持的语言: " .. table.concat(languages, ", "))
--- -- 输出: c, go, javascript, lua, python, rust, typescript
---
--- -- 检查当前文件类型是否被支持
--- local ft = vim.bo.filetype
--- local supported = code_block.get_supported_languages()
--- if vim.tbl_contains(supported, ft) then
---     print("当前文件类型 " .. ft .. " 支持代码块识别")
--- else
---     print("当前文件类型 " .. ft .. " 暂不支持，可以添加配置")
--- end
--- ```
---
---@return string[] 支持的语言名称列表，已排序且去重
function M.get_supported_languages()
	return Queries.get_supported_languages()
end

return M
