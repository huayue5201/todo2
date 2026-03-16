-- lua/todo2/ai/adapters/base.lua
-- 所有 AI 适配器的基类：统一接口 + 统一输出提取 + 统一错误链

local Base = {}

---------------------------------------------------------------------
-- 子类必须实现：流式生成
---------------------------------------------------------------------
function Base.generate_stream(prompt, on_chunk, on_done)
	error("适配器未实现 generate_stream()")
end

---------------------------------------------------------------------
-- 可选：同步生成（大多数模型不需要）
---------------------------------------------------------------------
function Base.generate(prompt)
	error("适配器未实现 generate()")
end

---------------------------------------------------------------------
-- ⭐ 统一模型输出提取器（跨所有模型）
-- 支持：
--   - Ollama: { response = "..." }
--   - OpenAI / DeepSeek / Claude: { choices = { { delta = { content = "..." } } } }
--   - LM Studio / vLLM: { text = "..." }
--   - llama.cpp: 纯文本
---------------------------------------------------------------------
function Base.extract_text(decoded)
	if not decoded then
		return nil
	end

	-- Ollama
	if decoded.response then
		return decoded.response
	end

	-- OpenAI / DeepSeek / Claude / LM Studio
	if decoded.choices and decoded.choices[1] then
		local c = decoded.choices[1]

		-- Chat completion delta
		if c.delta and c.delta.content then
			return c.delta.content
		end

		-- Chat completion message
		if c.message and c.message.content then
			return c.message.content
		end
	end

	-- vLLM / llama.cpp
	if decoded.text then
		return decoded.text
	end

	return nil
end

---------------------------------------------------------------------
-- ⭐ 工具：安全 JSON 解码
---------------------------------------------------------------------
function Base.try_json_decode(str)
	if not str or str == "" then
		return nil
	end
	local ok, decoded = pcall(vim.fn.json_decode, str)
	if ok and decoded then
		return decoded
	end
	return nil
end

---------------------------------------------------------------------
-- ⭐ 工具：向上层报告错误（统一格式）
---------------------------------------------------------------------
function Base.emit_error(on_chunk, msg)
	if on_chunk and msg then
		on_chunk("[adapter error] " .. tostring(msg))
	end
end

return Base
