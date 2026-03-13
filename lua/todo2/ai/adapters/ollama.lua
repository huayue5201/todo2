-- lua/todo2/ai/adapters/ollama.lua
-- 仅保留流式生成，删除同步 generate()

local M = {}
local cfg = require("todo2.ai.adapters.model_config.ollama_config")

---------------------------------------------------------------------
-- URL 构建
---------------------------------------------------------------------
local function build_url(path)
	local host = cfg.host or "http://127.0.0.1"
	local port = cfg.port and (":" .. tostring(cfg.port)) or ""
	return host .. port .. path
end

---------------------------------------------------------------------
-- JSON 转义（用于降级方案）
---------------------------------------------------------------------
local function json_string_escape(s)
	if not s then
		return ""
	end

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
	result = result:gsub("[%c]", function(c)
		return string.format("\\u%04x", string.byte(c))
	end)

	return result
end

---------------------------------------------------------------------
-- ⭐ 流式 generate_stream（基于 jobstart）
---------------------------------------------------------------------
function M.generate_stream(prompt, on_chunk, on_done)
	local url = build_url("/api/generate")

	local data = {
		model = cfg.model,
		prompt = prompt,
		temperature = cfg.temperature or 0.2,
		max_tokens = cfg.max_tokens or 1024,
		top_p = cfg.top_p or 0.95,
		stream = true,
	}

	local ok, payload = pcall(vim.fn.json_encode, data)
	if not ok or not payload then
		payload = string.format(
			'{"model":"%s","prompt":"%s","temperature":%s,"max_tokens":%s,"top_p":%s,"stream":true}',
			json_string_escape(cfg.model),
			json_string_escape(prompt),
			tostring(cfg.temperature or 0.2),
			tostring(cfg.max_tokens or 1024),
			tostring(cfg.top_p or 0.95)
		)
	end

	local cmd = {
		"curl",
		"-sN",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		payload,
		url,
	}

	local job_id = vim.fn.jobstart(cmd, {
		stdout_buffered = false,

		on_stdout = function(_, data, _)
			for _, line in ipairs(data) do
				if line and line ~= "" then
					local ok2, decoded = pcall(vim.fn.json_decode, line)
					if ok2 and decoded then
						if decoded.error then
							on_chunk("\n[Ollama 错误] " .. tostring(decoded.error))
						elseif decoded.response then
							on_chunk(decoded.response)
						end
					end
				end
			end
		end,

		on_stderr = function(_, data, _)
			-- 可选
		end,

		on_exit = function()
			if on_done then
				on_done()
			end
		end,
	})

	if job_id <= 0 then
		return false, "jobstart 启动失败"
	end

	return true, nil, job_id
end

return M
