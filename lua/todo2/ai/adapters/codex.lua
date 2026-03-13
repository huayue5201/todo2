-- lua/todo2/ai/adapters/codex.lua
-- Minimal OpenAI Codex adapter (synchronous curl-based)
-- Returns: string on success, or nil, err on failure

local cfg = require("todo2.ai.codex_config")
local M = {}

local function getenv(name)
	local ok, v = pcall(vim.fn.getenv, name)
	if ok and v and v ~= vim.NIL and v ~= "" then
		return v
	end
	return nil
end

local function json_escape(s)
	if not s then
		return ""
	end
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	return s
end

local function build_payload(prompt)
	local parts = {}
	table.insert(parts, string.format('"model":"%s"', cfg.model))
	table.insert(parts, string.format('"prompt":"%s"', json_escape(prompt)))
	table.insert(parts, string.format('"max_tokens":%d', cfg.max_tokens or 512))
	table.insert(parts, string.format('"temperature":%s', tostring(cfg.temperature or 0.2)))
	table.insert(parts, string.format('"top_p":%s', tostring(cfg.top_p or 1.0)))
	-- stop 可以按需添加
	return "{" .. table.concat(parts, ",") .. "}"
end

local function build_headers(api_key)
	local hdrs = {}
	hdrs["Content-Type"] = "application/json"
	hdrs["Authorization"] = "Bearer " .. api_key
	if cfg.headers then
		for k, v in pairs(cfg.headers) do
			hdrs[k] = v
		end
	end
	return hdrs
end

local function curl_post(url, payload, headers, timeout_ms)
	local cmd = { "curl", "-sS", "-X", "POST" }
	-- timeout (in seconds)
	local to_sec = math.max(1, math.floor((timeout_ms or cfg.timeout) / 1000))
	table.insert(cmd, "--max-time")
	table.insert(cmd, tostring(to_sec))
	for k, v in pairs(headers or {}) do
		table.insert(cmd, "-H")
		table.insert(cmd, string.format("%s: %s", k, v))
	end
	table.insert(cmd, "-d")
	table.insert(cmd, string.format("'%s'", payload:gsub("'", "'\\''")))
	table.insert(cmd, url)
	local full = table.concat(cmd, " ")
	local ok, res = pcall(vim.fn.system, full)
	if not ok then
		return nil, "curl 调用失败: " .. tostring(res)
	end
	return res, nil
end

local function extract_text_from_response(raw)
	if not raw or raw == "" then
		return nil, "empty response"
	end
	local ok, decoded = pcall(vim.fn.json_decode, raw)
	if not ok or not decoded then
		return nil, "无法解析 JSON 响应: " .. tostring(raw)
	end

	-- 错误字段优先
	if decoded.error then
		local err_msg = decoded.error
		if type(err_msg) == "table" and err_msg.message then
			err_msg = err_msg.message
		end
		return nil, tostring(err_msg)
	end

	-- OpenAI completions: choices[1].text
	if decoded.choices and type(decoded.choices) == "table" and decoded.choices[1] then
		local c = decoded.choices[1]
		if type(c) == "string" then
			return c, nil
		end
		if type(c) == "table" and c.text then
			return c.text, nil
		end
	end

	-- Some responses may include 'text' or 'output'
	if decoded.text and type(decoded.text) == "string" then
		return decoded.text, nil
	end
	if decoded.output and type(decoded.output) == "string" then
		return decoded.output, nil
	end

	return nil, "未在响应中找到生成文本字段"
end

--- 主接口：generate(prompt)
--- 返回 string 或 nil, err
function M.generate(prompt)
	if not prompt or prompt == "" then
		return nil, "prompt 为空"
	end

	local api_key = getenv("OPENAI_API_KEY")
	if not api_key then
		return nil, "未设置 OPENAI_API_KEY 环境变量"
	end

	local url = (cfg.api_base or "https://api.openai.com/v1") .. "/completions"
	local payload = build_payload(prompt)
	local headers = build_headers(api_key)

	-- 调用
	local raw, curl_err = curl_post(url, payload, headers, cfg.timeout)
	if not raw then
		return nil, curl_err
	end

	-- 解析并提取文本
	local text, perr = extract_text_from_response(raw)
	if not text then
		return nil, perr
	end

	return text
end

return M
