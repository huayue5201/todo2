-- lua/todo2/ai/codex_config.lua
local M = {}

-- OpenAI / Codex 配置
M.api_base = "https://api.openai.com/v1" -- 可替换为企业或代理地址
M.model = "code-davinci-002" -- 推荐 Codex 系列模型名（按需替换）
M.max_tokens = 512
M.temperature = 0.2
M.top_p = 1.0
M.timeout = 30 * 1000 -- 毫秒
M.headers = {
	["Content-Type"] = "application/json",
	-- Authorization header 由适配器从环境变量构造
}

return M
