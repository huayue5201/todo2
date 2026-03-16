-- lua/todo2/ai/stream/normalizer.lua
-- 统一规范化所有模型输出，确保 engine.on_chunk() 能解析
-- 支持：多段协议合并 / 自动补全字段 / 自动修复格式 / 去噪声

local M = {}

---------------------------------------------------------------------
-- 工具：安全 JSON 解码
---------------------------------------------------------------------
local function try_json_decode(chunk)
	local ok, decoded = pcall(vim.fn.json_decode, chunk)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return nil
end

---------------------------------------------------------------------
-- 1) 去掉 JSON 包裹（Ollama / OpenAI / Claude / DeepSeek）
---------------------------------------------------------------------
local function strip_json_wrappers(chunk)
	local decoded = try_json_decode(chunk)
	if not decoded then
		return chunk
	end

	-- Ollama
	if decoded.response then
		return decoded.response
	end

	-- OpenAI / DeepSeek / Claude
	if decoded.choices and decoded.choices[1] then
		local delta = decoded.choices[1].delta
		if delta and delta.content then
			return delta.content
		end
	end

	return chunk
end

---------------------------------------------------------------------
-- 2) 去掉 markdown 包裹
---------------------------------------------------------------------
local function strip_markdown(chunk)
	chunk = chunk:gsub("```[%w_]*", "")
	chunk = chunk:gsub("```", "")
	return chunk
end

---------------------------------------------------------------------
-- 3) 去掉自然语言解释（中英文）
---------------------------------------------------------------------
local function strip_explanations(chunk)
	local patterns = {
		"^%s*Sure.*\n",
		"^%s*Here is.*\n",
		"^%s*Below is.*\n",
		"^%s*I have updated.*\n",
		"^%s*Of course.*\n",
		"^%s*当然.*\n",
		"^%s*好的.*\n",
		"^%s*下面是.*\n",
	}

	for _, pat in ipairs(patterns) do
		chunk = chunk:gsub(pat, "")
	end

	return chunk
end

---------------------------------------------------------------------
-- 4) 提取协议头（支持多段协议，只取第一段）
---------------------------------------------------------------------
local function extract_first_protocol(chunk)
	local idx = chunk:find("@@TODO2_PATCH@@")
	if not idx then
		return nil
	end

	-- 截取从协议头开始的内容
	chunk = chunk:sub(idx)

	-- 如果模型重复输出协议头，只保留第一段
	local second = chunk:find("@@TODO2_PATCH@@", 2)
	if second then
		chunk = chunk:sub(1, second - 1)
	end

	return chunk
end

---------------------------------------------------------------------
-- 5) 自动补全协议格式（start/end/分隔符）
---------------------------------------------------------------------
local function fix_protocol_format(chunk)
	-- start/end 必须有空格
	chunk = chunk:gsub("start:(%d+)", "start: %1")
	chunk = chunk:gsub("end:(%d+)", "end: %1")

	-- 如果缺少分隔符 ":"，自动补上
	if not chunk:find("\n:%s*\n") then
		-- 找到 end 行后自动插入
		chunk = chunk:gsub("(end:%s*%d+)", "%1\n:\n")
	end

	return chunk
end

---------------------------------------------------------------------
-- 6) 自动修复补丁体（去掉多余空行）
---------------------------------------------------------------------
local function clean_patch_body(chunk)
	-- 去掉协议末尾多余空行
	chunk = chunk:gsub("\n+$", "\n")
	return chunk
end

---------------------------------------------------------------------
-- 主入口：规范化 chunk
---------------------------------------------------------------------
function M.normalize(raw)
	if not raw or raw == "" then
		return ""
	end

	local chunk = raw

	-- 1) 去 JSON 包裹
	chunk = strip_json_wrappers(chunk)

	-- 2) 去 markdown
	chunk = strip_markdown(chunk)

	-- 3) 去自然语言解释
	chunk = strip_explanations(chunk)

	-- 4) 提取协议头（只取第一段）
	chunk = extract_first_protocol(chunk)
	if not chunk then
		return "" -- 继续等待更多 chunk
	end

	-- 5) 修复协议格式
	chunk = fix_protocol_format(chunk)

	-- 6) 清理补丁体
	chunk = clean_patch_body(chunk)

	return chunk
end

return M
