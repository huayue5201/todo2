-- lua/todo2/store/config.lua
--- @module todo2.store.config
--- 统一配置管理（增强版：支持自动同步配置）

local M = {}

---------------------------------------------------------------------
-- 默认配置
---------------------------------------------------------------------
local DEFAULT_CONFIG = {
	-- 验证配置（仅行号验证与状态标记，不负责增删）
	verification = {
		enabled = true,
		auto_verify_interval = 86400, -- 24小时
		verify_on_file_save = true, -- 文件保存时验证行号
		batch_size = 50,
	},

	-- ⭐ 自动修复配置（重设计）
	autofix = {
		enabled = false, -- 默认关闭
		mode = "locate", -- locate / sync / both
		file_types = { -- 仅处理这些文件类型
			"*.md",
			"*.todo", -- TODO文件
			"*.rs",
			"*.lua",
			"*.py",
			"*.js",
			"*.ts",
			"*.go",
			"*.java",
			"*.cpp",
		},
	},
}

---------------------------------------------------------------------
-- 当前配置
---------------------------------------------------------------------
local current_config = {}

-- 初始化当前配置
for k, v in pairs(DEFAULT_CONFIG) do
	if type(v) == "table" then
		current_config[k] = vim.deepcopy(v)
	else
		current_config[k] = v
	end
end

---------------------------------------------------------------------
-- 公共API
---------------------------------------------------------------------
--- 获取配置
--- @param key string|nil 配置键，nil返回全部
--- @return any 配置值
function M.get(key)
	if not key then
		return vim.deepcopy(current_config)
	end

	local keys = vim.split(key, ".", { plain = true })
	local value = current_config

	for _, k in ipairs(keys) do
		if value and type(value) == "table" then
			value = value[k]
		else
			return nil
		end
	end

	return value
end

--- 设置配置
--- @param key string 配置键
--- @param value any 配置值
function M.set(key, value)
	local keys = vim.split(key, ".", { plain = true })
	local target = current_config

	-- 导航到目标位置
	for i = 1, #keys - 1 do
		local k = keys[i]
		if not target[k] or type(target[k]) ~= "table" then
			target[k] = {}
		end
		target = target[k]
	end

	-- 设置值
	local last_key = keys[#keys]
	target[last_key] = value

	-- 保存到文件（可选）
	M._save_config()
end

--- 更新配置（合并）
--- @param updates table 更新的配置
function M.update(updates)
	M._deep_merge(current_config, updates)
	M._save_config()
end

--- 重置为默认配置
function M.reset()
	current_config = {}
	for k, v in pairs(DEFAULT_CONFIG) do
		if type(v) == "table" then
			current_config[k] = vim.deepcopy(v)
		else
			current_config[k] = v
		end
	end
	M._save_config()
end

--- 加载配置文件
function M.load()
	local config_path = M._get_config_path()
	if vim.fn.filereadable(config_path) == 1 then
		local content = vim.fn.readfile(config_path)
		if content and #content > 0 then
			local json_str = table.concat(content, "\n")
			local ok, loaded = pcall(vim.fn.json_decode, json_str)
			if ok and loaded and type(loaded) == "table" then
				M._deep_merge(current_config, loaded)
			end
		end
	end
end

---------------------------------------------------------------------
-- 内部函数
---------------------------------------------------------------------
function M._get_config_path()
	local project_root = require("todo2.store.meta").get_project_root()
	return project_root .. "/.todo2/config.json"
end

function M._save_config()
	local config_path = M._get_config_path()
	local dir = vim.fn.fnamemodify(config_path, ":h")

	-- 确保目录存在
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	local json = vim.fn.json_encode(current_config)
	vim.fn.writefile({ json }, config_path)
end

function M._deep_merge(target, source)
	for k, v in pairs(source) do
		if type(v) == "table" and type(target[k]) == "table" then
			M._deep_merge(target[k], v)
		else
			target[k] = v
		end
	end
end

--- 初始化配置（由store.init调用）
function M.setup()
	M.load()
	-- 其他初始化由调用方负责
end

return M
