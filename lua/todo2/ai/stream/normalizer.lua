-- lua/todo2/ai/stream/normalizer.lua
-- 统一规范化所有模型输出（新协议版）

local M = {}

local function try_json_decode(chunk)
	local ok, decoded = pcall(vim.fn.json_decode, chunk)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return nil
end

local function strip_json_wrappers(chunk)
	local decoded = try_json_decode(chunk)
	if not decoded then
		return chunk
	end

	if decoded.response then
		return decoded.response
	end

	if decoded.choices and decoded.choices[1] then
		local delta = decoded.choices[1].delta
		if delta and delta.content then
			return delta.content
		end
	end

	return chunk
end

-- 强力修复新协议标记
local function fix_protocol_markers(chunk)
	chunk = chunk:gsub("<%s*<%s*<%s*TODO2%s*_?%s*PATCH%s*_?%s*BEGIN%s*>%s*>%s*>", "<<<TODO2_PATCH_BEGIN>>>")
	chunk = chunk:gsub("<%s*<%s*<%s*TODO2%s*_?%s*PATCH%s*_?%s*HEADER%s*>%s*>%s*>", "<<<TODO2_PATCH_HEADER>>>")
	chunk = chunk:gsub("<%s*<%s*<%s*TODO2%s*_?%s*PATCH%s*_?%s*CODE%s*>%s*>%s*>", "<<<TODO2_PATCH_CODE>>>")
	chunk = chunk:gsub("<%s*<%s*<%s*TODO2%s*_?%s*PATCH%s*_?%s*END%s*>%s*>%s*>", "<<<TODO2_PATCH_END>>>")
	return chunk
end

-- 修复 key=value 被拆碎的情况（如 s t a r t = 1 5）
local function fix_broken_kv(chunk)
	-- 把 "s t a r t" 这种合并成 "start"
	chunk = chunk:gsub("s%s*t%s*a%s*r%s*t", "start")
	chunk = chunk:gsub("e%s*n%s*d", "end")
	chunk = chunk:gsub("s%s*i%s*g%s*n%s*a%s*t%s*u%s*r%s*e%s*_?%s*h%s*a%s*s%s*h", "signature_hash")
	chunk = chunk:gsub("m%s*o%s*d%s*e", "mode")

	-- 修复 "start = 1 5" → "start=15"
	chunk = chunk:gsub("(start)%s*=%s*(%d+)%s+(%d+)", "%1=%2%3")
	chunk = chunk:gsub("(end)%s*=%s*(%d+)%s+(%d+)", "%1=%2%3")

	-- 修复换行拆开的数字
	chunk = chunk:gsub("(start)%s*=%s*(%d+)\n(%d+)", "%1=%2%3")
	chunk = chunk:gsub("(end)%s*=%s*(%d+)\n(%d+)", "%1=%2%3")

	return chunk
end

-- 修复空格分隔字符（保留原有逻辑，但更保守）
local function fix_space_separated(chunk)
	if chunk:match("%a %a") then
		local fixed = chunk:gsub("([%w_])%s+([%w_])", "%1%2")
		fixed = fixed:gsub("\n%s+", "\n")
		fixed = fixed:gsub("%s+([,;:{}()<>%[%]%=])", "%1")
		fixed = fixed:gsub("([,;:{}()<>%[%]%=])%s+", "%1")
		return fixed
	end
	return chunk
end

-- 保留你原来的 Go 语法修复
local function fix_go_syntax(chunk)
	chunk = chunk:gsub("func%s+(%w+)%s*%(([^)]*)%)%s*{", function(name, params)
		params = params:gsub("%s+", " ")
		return "func " .. name .. "(" .. params .. ") {"
	end)
	chunk = chunk:gsub("(%w+)\n=", "%1 =")
	chunk = chunk:gsub("=\n(%w+)", "= %1")
	return chunk
end

function M.normalize(raw)
	if not raw or raw == "" then
		return ""
	end

	local chunk = raw

	-- 1) 去 JSON 包裹
	chunk = strip_json_wrappers(chunk)
	if chunk == "" then
		return ""
	end

	-- 2) 修复新协议标记
	chunk = fix_protocol_markers(chunk)

	-- 3) 修复 key=value 拆碎
	chunk = fix_broken_kv(chunk)

	-- 4) 修复空格分隔字符
	chunk = fix_space_separated(chunk)

	-- 5) 修复 Go 语法（可选）
	chunk = fix_go_syntax(chunk)

	return chunk
end

return M
