-- lua/todo2/ai/adapters/ollama.lua
return {
	backend = "ollama",
	display_name = "Ollama (via Rust)",
	host = "http://127.0.0.1",
	port = 11434,
	model = "gemma3:4b",
	temperature = 0.2,
	max_tokens = 1024,
	top_p = 0.95,
	stop = nil,
	timeout = 120, -- 增加到 120 秒（2 分钟）
	headers = {},
}
