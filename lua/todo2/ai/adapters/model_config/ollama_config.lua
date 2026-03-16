-- lua/todo2/ai/adapters/model_config/ollama_config.lua

return {
	backend = "ollama",
	display_name = "Gemma 3 (Ollama)",

	host = "http://127.0.0.1",
	port = 11434,

	model = "gemma3:latest",

	temperature = 0.2,
	max_tokens = 1024,
	top_p = 0.95,
	stop = nil,

	timeout = 30, -- 秒

	headers = {},
}
