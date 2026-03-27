-- lua/todo2/ai/models/deepseek-r1.lua
-- DeepSeek R1 推理模型配置

return {
	backend = "deepseek",
	display_name = "DeepSeek R1 (推理)",
	model = "deepseek-reasoner", -- R1 推理模型

	-- 更安全的方式
	api_key = os.getenv("DEEPSEEK_API_KEY") or "sk-xxx",
	url = "https://api.deepseek.com/chat/completions",

	temperature = 0.6, -- R1 推荐较低温度
	max_tokens = 8192, -- R1 支持更长输出
	timeout = 120, -- 推理模型需要更多时间

	top_p = 0.95,
}
