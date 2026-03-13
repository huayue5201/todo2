-- lua/todo2/ai/adapters/opencode.lua
-- OpenAI gpt-4.1-mini 代码生成适配器（稳定版）

local M = {}

local function request_openai(prompt)
	local body = vim.fn.json_encode({
		model = "gpt-4.1-mini",
		messages = {
			{ role = "user", content = prompt },
		},
	})

	local result = vim.fn.system({
		"curl",
		"-s",
		"-X",
		"POST",
		"https://api.openai.com/v1/chat/completions",
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. (os.getenv("OPENAI_API_KEY") or ""),
		"-d",
		body,
	})

	-- JSON 解析
	local ok, decoded = pcall(vim.fn.json_decode, result)
	if not ok or not decoded then
		return nil, "OpenAI 返回无效 JSON"
	end

	if decoded.error then
		return nil, decoded.error.message or "OpenAI API 错误"
	end

	if not decoded.choices or not decoded.choices[1] then
		return nil, "OpenAI 未返回 choices"
	end

	local content = decoded.choices[1].message.content
	if not content or content == "" then
		return nil, "OpenAI 未生成内容"
	end

	return content, nil
end

--- 生成代码
--- @param prompt string
--- @return string|nil 成功返回代码字符串，失败返回 nil
function M.generate(prompt)
	local content, err = request_openai(prompt)
	if not content then
		-- 记录错误但不返回错误表，保持简单
		vim.notify("OpenAI 生成失败: " .. (err or "未知错误"), vim.log.levels.ERROR)
		return nil
	end

	return content -- ⭐ 直接返回字符串，不再包装成表
end

return M
