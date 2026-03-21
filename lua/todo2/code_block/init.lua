-- lua/todo2/code_block/init.lua
-- 代码块采集模块入口

local Engine = require("todo2.code_block.core.engine")
local Queries = require("todo2.code_block.queries")

local M = {}

-- 导出查询配置（供外部扩展）
M.queries = Queries

-- 导出主要 API
M.get_block_at_line = Engine.get_block_at_line
M.get_all_blocks = Engine.get_all_blocks
M.get_block_text = Engine.get_block_text
M.get_block_signature = Engine.get_block_signature
M.get_block_name = Engine.get_block_name
M.get_block_type = Engine.get_block_type
M.is_method = Engine.is_method
M.get_receiver = Engine.get_receiver
M.clear_cache = Engine.clear_cache
M.setup = Engine.setup
M.get_config = Engine.get_config

--- 添加新语言支持
---@param ft string 文件类型
---@param lang_config table 语言配置
function M.add_language(ft, lang_config)
	Queries.add(ft, lang_config)
end

--- 获取支持的语言列表
function M.get_supported_languages()
	return Queries.get_supported_languages()
end

return M
