-- lua/todo2/ai/adapters/ollama.lua
local M = {}
local cfg = require("todo2.ai.adapters.model_config.ollama_config")

local function build_url(path)
	local host = cfg.host or "http://127.0.0.1"
	local port = cfg.port and (":" .. tostring(cfg.port)) or ""
	return host .. port .. path
end

-- ⭐ 完整的 JSON 字符串转义
local function json_string_escape(s)
	if not s then
		return ""
	end

	-- 处理特殊字符
	local escapes = {
		['"'] = '\\"',
		["\\"] = "\\\\",
		["/"] = "\\/",
		["\b"] = "\\b",
		["\f"] = "\\f",
		["\n"] = "\\n",
		["\r"] = "\\r",
		["\t"] = "\\t",
	}

	local result = s:gsub('["\\/\b\f\n\r\t]', escapes)

	-- 处理其他控制字符（范围 \x00-\x1F 除了上面已处理的）
	result = result:gsub("[%c]", function(c)
		return string.format("\\u%04x", string.byte(c))
	end)

	return result
end

-- ⭐ 使用 vim.fn.json_encode 来生成合法的 JSON
local function build_payload(prompt)
	local data = {
		model = cfg.model,
		prompt = prompt,
		temperature = cfg.temperature or 0.2,
		max_tokens = cfg.max_tokens or 1024,
		top_p = cfg.top_p or 0.95,
		stream = false,
	}

	-- 使用 Neovim 内置的 JSON 编码
	local ok, payload = pcall(vim.fn.json_encode, data)
	if not ok or not payload then
		-- 降级方案：手动构建
		return string.format(
			'{"model":"%s","prompt":"%s","temperature":%s,"max_tokens":%s,"top_p":%s,"stream":false}',
			json_string_escape(cfg.model),
			json_string_escape(prompt),
			tostring(cfg.temperature or 0.2),
			tostring(cfg.max_tokens or 1024),
			tostring(cfg.top_p or 0.95)
		)
	end

	return payload
end

function M.generate(prompt)
	local url = build_url("/api/generate")
	local payload = build_payload(prompt)

	print("Ollama URL:", url)
	print("Ollama Payload:", payload)

	-- ⭐ 创建临时文件来传递 JSON，避免命令行转义问题
	local tmp_file = os.tmpname()
	local f = io.open(tmp_file, "w")
	if f then
		f:write(payload)
		f:close()
	end

	local curl_cmd = {
		"curl",
		"-s",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		"@" .. tmp_file, -- ⭐ 从文件读取 JSON
		url,
	}

	local cmd = table.concat(curl_cmd, " ")
	print("Curl command:", cmd)

	local ok, result = pcall(vim.fn.system, cmd)

	-- 清理临时文件
	os.remove(tmp_file)

	if not ok then
		return nil, "curl 调用失败: " .. tostring(result)
	end

	print("Raw response:", result)

	-- 处理多行响应
	local lines = vim.split(result, "\n", { plain = true })
	for i = #lines, 1, -1 do
		if lines[i] and lines[i] ~= "" then
			result = lines[i]
			break
		end
	end

	local ok2, decoded = pcall(vim.fn.json_decode, result)
	if not ok2 or not decoded then
		return nil, "无法解析 Ollama 返回: " .. tostring(result)
	end

	print("Decoded:", vim.inspect(decoded))

	if decoded.error then
		return nil, "Ollama 错误: " .. tostring(decoded.error)
	end

	if decoded.response and type(decoded.response) == "string" then
		-- ⭐ 清理响应内容
		local response = decoded.response
		response = response:gsub("^%s+", ""):gsub("%s+$", "")
		return response
	end

	return nil, "未找到可用的生成字段"
end

return M
