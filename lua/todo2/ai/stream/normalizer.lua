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
-- 2) 强力修复被错误换行的代码
-- 将这种格式：
-- c
-- l
-- i
-- e
-- n
-- t
-- 修复为：client
---------------------------------------------------------------------
local function aggressive_fix_broken_code(chunk)
	-- 按行分割
	local lines = vim.split(chunk, "\n")
	local result = {}
	local current_line = ""
	local in_code_block = false

	for i = 1, #lines do
		local line = lines[i]

		-- 检测协议标记
		if line:find("@@TODO2_PATCH@@") then
			table.insert(result, line)
			in_code_block = true
		elseif line:find("start:") or line:find("end:") or line == ":" then
			table.insert(result, line)
		elseif in_code_block then
			-- 如果是单个字符或短标记，累积起来
			if #line <= 3 and line:match("^[a-zA-Z0-9_.,=:;{}()<>%[%]%+%-%*/&|!\"'\\]+$") then
				current_line = current_line .. line
			else
				-- 如果之前有累积的字符，先加入结果
				if current_line ~= "" then
					table.insert(result, current_line)
					current_line = ""
				end
				-- 加入当前行（可能是空行或注释）
				if line ~= "" then
					table.insert(result, line)
				end
			end
		else
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
-- 3) 修复特定的损坏模式
---------------------------------------------------------------------
local function fix_specific_patterns(chunk)
	-- 修复 "c l i e n t" 这种带空格的模式
	chunk = chunk:gsub("(%a) (%a)", "%1%2")

	-- 修复换行后的单个字符
	chunk = chunk:gsub("\n(%a)\n(%a)", "\n%1%2")
	chunk = chunk:gsub("\n(%a)\n(%a)\n(%a)", "\n%1%2%3")

	-- 修复常见的 Go 语法
	chunk = chunk:gsub("func%s+%(([^)]*)%)", "func(%1)") -- 修复函数参数
	chunk = chunk:gsub("%. ([a-zA-Z])", ".%1") -- 修复点号后的空格

	-- 修复 URL 和字符串
	chunk = chunk:gsub('"([^"]*)"', function(s)
		-- 移除字符串内部的换行和多余空格
		s = s:gsub("\n", ""):gsub("%s+", " ")
		return '"' .. s .. '"'
	end)

	return chunk
end

---------------------------------------------------------------------
-- 4) 修复常见的 Go 代码格式
---------------------------------------------------------------------
local function fix_go_syntax(chunk)
	-- 修复导入语句
	chunk = chunk:gsub('import %(\n\t"([^"]+)"\n%)', 'import (\n\t"\1"\n)')

	-- 修复结构体定义
	chunk = chunk:gsub("type%s+(%w+)%s+struct%s+{", "type \1 struct {")

	-- 修复函数定义
	chunk = chunk:gsub("func%s+(%w+)%s*%(([^)]*)%)%s*{", function(name, params)
		params = params:gsub("%s+", " ") -- 规范化参数空格
		return "func " .. name .. "(" .. params .. ") {"
	end)

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

	-- 2) 如果 chunk 是空字符串，返回空
	if chunk == "" then
		return ""
	end

	-- 3) 强力修复被错误换行的代码
	chunk = aggressive_fix_broken_code(chunk)

	-- 4) 修复特定模式
	chunk = fix_specific_patterns(chunk)

	-- 5) 修复 Go 语法
	chunk = fix_go_syntax(chunk)

	return chunk
end

return M
