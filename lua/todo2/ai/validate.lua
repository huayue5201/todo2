-- lua/todo2/ai/validate.lua
-- 语法验证模块：支持多语言快速语法检查

local M = {}

local uv = vim.loop or vim.uv

-- 语言检查器配置
local checkers = {
	lua = {
		cmd = { "luac", "-p" },
		parse_error = function(output)
			-- luac 输出格式: "luac: <filename>: syntax error near 'xxx'"
			return output:match("syntax error%s+(.+)") or output:match(": (.+)")
		end,
	},
	python = {
		cmd = { "python", "-m", "py_compile" },
		parse_error = function(output)
			-- Python 输出格式: "  File \"<filename>\", line X\n    ...\nSyntaxError: ..."
			local err = output:match("SyntaxError: (.+)") or output:match("IndentationError: (.+)")
			return err or output:sub(1, 200)
		end,
	},
	go = {
		cmd = { "go", "fmt" },
		parse_error = function(output)
			-- go fmt 输出格式: "<filename>: line X: ..."
			local err = output:match(": (.+)")
			return err or output:sub(1, 200)
		end,
	},
	rust = {
		cmd = { "rustc", "-Z", "no-codegen", "--error-format=short" },
		parse_error = function(output)
			-- rustc 输出: "error: ..."
			local err = output:match("error: (.+)")
			return err or output:sub(1, 200)
		end,
	},
	typescript = {
		cmd = { "tsc", "--noEmit", "--pretty", "false" },
		parse_error = function(output)
			-- tsc 输出: "TS1234: ..."
			local err = output:match("TS%d+: (.+)")
			return err or output:sub(1, 200)
		end,
	},
	javascript = {
		cmd = { "node", "--check" },
		parse_error = function(output)
			-- node --check 输出: "SyntaxError: ..."
			local err = output:match("SyntaxError: (.+)")
			return err or output:sub(1, 200)
		end,
	},
}

-- 语言别名映射
local lang_aliases = {
	lua = "lua",
	luau = "lua",
	python = "python",
	py = "python",
	go = "go",
	golang = "go",
	rust = "rust",
	rs = "rust",
	typescript = "typescript",
	ts = "typescript",
	javascript = "javascript",
	js = "javascript",
}

---获取语言的检查命令
---@param lang string
---@return table|nil
function M.get_checker(lang)
	local normalized = lang_aliases[lang:lower()] or lang:lower()
	return checkers[normalized]
end

---执行同步命令并返回输出
---@param cmd table 命令和参数
---@param stdin string|nil 标准输入内容
---@param timeout_ms integer 超时毫秒
---@return boolean success
---@return string output
local function run_sync(cmd, stdin, timeout_ms)
	timeout_ms = timeout_ms or 5000

	local stdout_chunks = {}
	local stderr_chunks = {}
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)
	local done = false
	local exit_code = nil

	local handle = uv.spawn(cmd[1], {
		args = cmd,
		stdio = { nil, stdout, stderr },
	}, function(code)
		exit_code = code
		stdout:close()
		stderr:close()
		handle:close()
		done = true
	end)

	if not handle then
		return false, "无法启动检查器: " .. cmd[1]
	end

	-- 如果有 stdin，写入
	if stdin then
		local stdin_pipe = uv.new_pipe(false)
		uv.pipe_open(stdin_pipe, 0)
		uv.write(stdin_pipe, stdin, function()
			stdin_pipe:close()
		end)
	end

	stdout:read_start(function(err, data)
		if data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)

	stderr:read_start(function(err, data)
		if data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)

	-- 等待完成
	local start = uv.hrtime() / 1e6
	while not done do
		if (uv.hrtime() / 1e6) - start > timeout_ms then
			handle:kill("sigterm")
			return false, "检查超时"
		end
		vim.wait(10)
	end

	local output = table.concat(stdout_chunks) .. table.concat(stderr_chunks)
	return exit_code == 0, output
end

---语法检查
---@param code string 代码内容
---@param lang string 语言
---@param filepath string|nil 文件路径（用于临时文件）
---@return boolean ok
---@return string|nil error_message
function M.syntax_check(code, lang, filepath)
	if not code or code == "" then
		return true, nil
	end

	local checker = M.get_checker(lang)
	if not checker then
		-- 无检查器，跳过验证
		return true, nil
	end

	-- 创建临时文件
	local tmp_file = vim.fn.tempname()
	if filepath then
		-- 保留扩展名以便检查器识别
		local ext = filepath:match("%.[^.]+$") or ""
		if ext ~= "" then
			tmp_file = tmp_file .. ext
		end
	end

	local f = io.open(tmp_file, "w")
	if not f then
		return false, "无法创建临时文件"
	end
	f:write(code)
	f:close()

	-- 构建命令
	local cmd = { unpack(checker.cmd) }
	table.insert(cmd, tmp_file)

	-- 执行检查
	local ok, output = run_sync(cmd, nil, 5000)

	-- 清理临时文件
	os.remove(tmp_file)

	if not ok then
		local err = checker.parse_error and checker.parse_error(output) or output:sub(1, 200)
		return false, err or "语法错误"
	end

	return true, nil
end

---检查代码块是否完整（简单启发式）
---@param code string
---@param lang string
---@return boolean
function M.is_complete(code, lang)
	if not code or code == "" then
		return false
	end

	-- 简单的括号匹配检查
	local stack = {}
	local pairs = {
		["("] = ")",
		["["] = "]",
		["{"] = "}",
	}

	-- 忽略字符串和注释中的括号（简化版）
	for i = 1, #code do
		local char = code:sub(i, i)
		if pairs[char] then
			table.insert(stack, char)
		elseif char == ")" or char == "]" or char == "}" then
			local last = table.remove(stack)
			if not last or pairs[last] ~= char then
				return false
			end
		end
	end

	return #stack == 0
end

---获取支持的语言列表
---@return string[]
function M.get_supported_languages()
	local langs = {}
	for lang in pairs(checkers) do
		table.insert(langs, lang)
	end
	table.sort(langs)
	return langs
end

return M
