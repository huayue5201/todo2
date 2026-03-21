-- lua/todo2/code_block/queries/init.lua
-- 查询配置加载器

local M = {}

-- 语言模块缓存
local modules = {}

--- 加载语言模块
---@param ft string
---@return table|nil
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
---@param ft string
---@return table|nil
function M.get(ft)
	return load_lang(ft)
end

--- 获取所有支持的语言
function M.get_supported_languages()
	local langs = {}
	for ft, _ in pairs(modules) do
		table.insert(langs, ft)
	end
	-- 也可以扫描文件系统，但缓存已经足够
	return langs
end

--- 动态添加语言配置（用于运行时扩展）
---@param ft string
---@param config table
function M.add(ft, config)
	modules[ft] = config
end

return M
