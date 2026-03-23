-- lua/todo2/ai/stream/normalizer.lua
-- 统一规范化所有模型输出

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
-- 1) 去掉 JSON 包裹
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 2) 修复被拆分的协议标记
---------------------------------------------------------------------
local function fix_protocol_marker(chunk)
	-- 修复各种被拆分的协议标记
	chunk = chunk:gsub(
		"@[ \n]*@[ \n]*T[ \n]*O[ \n]*D[ \n]*O[ \n]*2[ \n]*_[ \n]*P[ \n]*A[ \n]*T[ \n]*C[ \n]*H[ \n]*@[ \n]*@",
		"@@TODO2_PATCH@@"
	)

	-- 修复 start: 和 end:
	chunk = chunk:gsub("s[ \n]*t[ \n]*a[ \n]*r[ \n]*t[ \n]*:", "start:")
	chunk = chunk:gsub("e[ \n]*n[ \n]*d[ \n]*:", "end:")

	return chunk
end

---------------------------------------------------------------------
-- 3) 修复被拆分的行号
---------------------------------------------------------------------
local function fix_broken_numbers(chunk)
	chunk = chunk:gsub("start:%s*(%d+)%s+(%d+)", "start: %1%2")
	chunk = chunk:gsub("end:%s*(%d+)%s+(%d+)", "end: %1%2")
	chunk = chunk:gsub("start:%s*(%d+)\n(%d+)", "start: %1%2")
	chunk = chunk:gsub("end:%s*(%d+)\n(%d+)", "end: %1%2")
	return chunk
end

---------------------------------------------------------------------
-- 4) 修复被拆分的代码（核心修复）
-- 将这种格式：
-- e
-- n
-- d
-- 修复为：end
---------------------------------------------------------------------
local function fix_broken_code(chunk)
	if not chunk or chunk == "" then
		return chunk
	end

	-- 按行分割
	local lines = vim.split(chunk, "\n")
	local result = {}
	local current_line = ""
	local in_code = false
	local in_protocol = false

	for i, line in ipairs(lines) do
		-- 检测协议开始
		if line:find("@@TODO2_PATCH@@") then
			in_protocol = true
			in_code = false
			if current_line ~= "" then
				table.insert(result, current_line)
				current_line = ""
			end
			table.insert(result, line)
		-- 检测协议结束标记 ":"
		elseif in_protocol and line == ":" then
			in_protocol = false
			in_code = true
			table.insert(result, line)
		-- 在协议头中（收集 start/end/signature_hash）
		elseif in_protocol then
			table.insert(result, line)
		-- 在代码块中，进行修复
		elseif in_code then
			local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")

			-- 如果是单个字符（或很短），累积起来
			if #trimmed <= 3 and trimmed:match("^[%w_.,=:;{}()<>%[%]%+%-%*/&|!\"'\\]$") then
				current_line = current_line .. trimmed
			else
				-- 有累积的字符，先输出
				if current_line ~= "" then
					table.insert(result, current_line)
					current_line = ""
				end
				-- 输出当前行
				if line ~= "" then
					table.insert(result, line)
				end
			end
		else
			-- 普通行
			if current_line ~= "" then
				table.insert(result, current_line)
				current_line = ""
			end
			table.insert(result, line)
		end
	end

	-- 处理最后的累积
	if current_line ~= "" then
		table.insert(result, current_line)
	end

	return table.concat(result, "\n")
end

---------------------------------------------------------------------
-- 5) 修复空格分隔的字符（如 "e n d" → "end"）
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 6) 修复常见的 Go 语法
---------------------------------------------------------------------
local function fix_go_syntax(chunk)
	chunk = chunk:gsub("func%s+(%w+)%s*%(([^)]*)%)%s*{", function(name, params)
		params = params:gsub("%s+", " ")
		return "func " .. name .. "(" .. params .. ") {"
	end)
	chunk = chunk:gsub("(%w+)\n=", "%1 =")
	chunk = chunk:gsub("=\n(%w+)", "= %1")
	return chunk
end

---------------------------------------------------------------------
-- 主入口
---------------------------------------------------------------------
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

	-- 2) 修复协议标记
	chunk = fix_protocol_marker(chunk)

	-- 3) 修复被拆分的行号
	chunk = fix_broken_numbers(chunk)

	-- 4) 修复被拆分的代码（跨行单字符）
	chunk = fix_broken_code(chunk)

	-- 5) 修复空格分隔的字符
	chunk = fix_space_separated(chunk)

	-- 6) 修复 Go 语法
	chunk = fix_go_syntax(chunk)

	return chunk
end

return M
