-- lua/todo2/ai/init.lua
-- AI 后端管理器：负责注册适配器、切换模型、提供统一入口

local M = {}

local backends = {}
local current_backend = nil

M.current_config = nil

---------------------------------------------------------------------
-- 注册适配器
---------------------------------------------------------------------
function M.register(name, adapter)
	adapter.name = name
	backends[name] = adapter
end

---------------------------------------------------------------------
-- 切换模型
---------------------------------------------------------------------
function M.set_model(cfg)
	if not cfg or not cfg.backend then
		error("无效的模型配置（缺少 backend 字段）")
	end

	local adapter = backends[cfg.backend]
	if not adapter then
		error("未注册的模型后端: " .. tostring(cfg.backend))
	end

	M.current_config = cfg
	current_backend = adapter

	adapter.model_name = cfg.model
	adapter.config = cfg
end

---------------------------------------------------------------------
-- 获取当前适配器
---------------------------------------------------------------------
local function ensure_backend()
	if not current_backend then
		error("未选择任何模型，请先执行 :TodoAISelectModel")
	end
	return current_backend
end

function M._get_current()
	return ensure_backend()
end

---------------------------------------------------------------------
-- 统一流式接口
---------------------------------------------------------------------
function M.generate_stream(prompt, on_chunk, on_done)
	local backend = ensure_backend()
	return backend.generate_stream(prompt, on_chunk, on_done)
end

---------------------------------------------------------------------
-- 自动扫描并加载所有适配器
---------------------------------------------------------------------
local function load_all_adapters()
	local src = debug.getinfo(1, "S").source:gsub("^@", "")
	local base_dir = src:match("(.*/)") .. "adapters"

	local files = vim.fn.glob(base_dir .. "/*.lua", false, true)

	for _, file in ipairs(files) do
		local name = file:match("adapters/(.+)%.lua$")
		if name and name ~= "base" then
			local ok, loader = pcall(require, "todo2.ai.adapters." .. name)
			if ok and type(loader) == "function" then
				loader(M)
			end
		end
	end
end

load_all_adapters()

---------------------------------------------------------------------
-- 扫描 model_config（用于自动恢复）
---------------------------------------------------------------------
local function scan_model_configs()
	local src = debug.getinfo(1, "S").source:gsub("^@", "")
	local base_dir = src:match("(.*/)") .. "adapters/model_config"

	local files = vim.fn.glob(base_dir .. "/*.lua", false, true)
	local configs = {}

	for _, file in ipairs(files) do
		local name = file:match("model_config/(.+)%.lua$")
		if name then
			local ok, cfg = pcall(require, "todo2.ai.adapters.model_config." .. name)
			if ok and type(cfg) == "table" and cfg.backend and cfg.display_name then
				table.insert(configs, cfg)
			end
		end
	end

	return configs
end

---------------------------------------------------------------------
-- 自动恢复上次选择的模型
---------------------------------------------------------------------
local state = require("todo2.ai.state")
local last = state.load()

if last then
	local configs = scan_model_configs()
	for _, cfg in ipairs(configs) do
		if cfg.backend == last.backend and cfg.model == last.model then
			M.set_model(cfg)
			vim.notify("已自动恢复模型：" .. cfg.display_name)
			break
		end
	end
end

return M
