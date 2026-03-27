-- lua/todo2/ai/init.lua
-- AI 模块主入口：统一网关 + 模型管理

local M = {}

local current_backend = nil
M.current_config = nil

-- 加载网关（与 Rust 服务通信）
local gateway = require("todo2.ai.gateway")

-- 注册网关适配器（统一入口）
function M.register_gateway()
	local adapter = {
		name = "gateway",
		generate_stream = function(prompt, on_chunk, on_done)
			local config = M.current_config
			local timeout = config and config.timeout or 120

			return gateway.send({
				messages = {
					{ role = "system", content = "You are a code assistant. Output code only, no explanations." },
					{ role = "user", content = prompt },
				},
				options = {
					stream = true,
					timeout = timeout, -- 显式传递 timeout
				},
				on_chunk = on_chunk,
				on_complete = on_done,
				on_error = function(err)
					vim.notify(err.message, vim.log.levels.ERROR)
					if on_done then
						on_done()
					end
				end,
			})
		end,
	}
	current_backend = adapter
end

-- 切换模型
function M.set_model(cfg)
	if not cfg or not cfg.backend then
		error("无效的模型配置（缺少 backend 字段）")
	end

	-- 确保网关已注册
	if not current_backend then
		M.register_gateway()
	end

	M.current_config = cfg
end

-- 获取当前适配器
local function ensure_backend()
	if not current_backend then
		M.register_gateway()
	end
	return current_backend
end

-- 统一流式接口
function M.generate_stream(prompt, on_chunk, on_done)
	local backend = ensure_backend()
	return backend.generate_stream(prompt, on_chunk, on_done)
end

-- 扫描模型配置（从 models 目录）
local function scan_model_configs()
	local src = debug.getinfo(1, "S").source:gsub("^@", "")
	local base_dir = src:match("(.*/)")
	-- 模型配置现在放在 models 目录下
	local config_dir = base_dir .. "models"

	local files = vim.fn.glob(config_dir .. "/*.lua", false, true)
	local configs = {}

	for _, file in ipairs(files) do
		local name = file:match("models/(.+)%.lua$")
		if name then
			local ok, cfg = pcall(require, "todo2.ai.models." .. name)
			if ok and type(cfg) == "table" and cfg.backend and cfg.display_name then
				table.insert(configs, cfg)
			end
		end
	end

	return configs
end

-- 自动恢复上次选择的模型
local state = require("todo2.ai.state")
local last = state.load()

if last then
	local configs = scan_model_configs()
	for _, cfg in ipairs(configs) do
		if cfg.backend == last.backend and cfg.model == last.model then
			M.set_model(cfg)
			vim.notify("已自动恢复模型：" .. cfg.display_name, vim.log.levels.INFO)
			break
		end
	end
end

return M
