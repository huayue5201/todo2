-- lua/todo2/ai/ollama_config.lua
-- 本地 Ollama 配置（可按需修改）
local M = {}

-- Ollama 服务地址（本地默认）
M.host = "http://127.0.0.1"
M.port = 11434

-- 使用的模型名称（在本地 Ollama 中已 pull 的模型名）
M.model = "gemma3:latest"

-- 请求参数（可按需调整）
M.temperature = 0.2
M.max_tokens = 1024
M.top_p = 0.95
M.stop = nil -- 或 {"\n\n"} 等

-- 超时（毫秒）
M.timeout = 30 * 1000

-- 是否启用 TLS（如果你用反向代理或 https）
M.tls = false

-- 可选：额外 HTTP headers（例如自定义认证）
M.headers = {
	-- ["Authorization"] = "Bearer xxxxx", -- 本地通常不需要
}

return M
