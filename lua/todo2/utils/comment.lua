-- lua/todo2/utils/comment.lua
local M = {}

--- 从commentstring中提取注释前缀
--- @param commentstr string
--- @return string|nil
local function extract_prefix(commentstr)
	if not commentstr or commentstr == "" then
		return nil
	end

	-- 尝试匹配标准格式: "// %s" 或 "-- %s" 或 "/* %s */"
	local prefix = commentstr:match("^(.-)%%s")
	if prefix then
		return prefix:gsub("%s+$", "")
	end

	-- 处理没有占位符的情况 (如 "# " 或 "//")
	return commentstr:match("^%s*(%S+)%s*$") or commentstr:match("^%s*(%S+)")
end

--- 根据缓冲区获取注释前缀
--- @param bufnr number|nil 缓冲区号，默认当前缓冲区
--- @return string
function M.get_prefix(bufnr)
	bufnr = bufnr or 0

	-- 确保缓冲区有效
	if bufnr ~= 0 and not vim.api.nvim_buf_is_valid(bufnr) then
		bufnr = 0
	end

	-- 尝试从commentstring获取
	local cs = vim.api.nvim_get_option_value("commentstring", { buf = bufnr })
	if cs and cs ~= "" then
		local prefix = extract_prefix(cs)
		if prefix then
			return prefix
		end
	end

	-- 降级：基于文件类型
	local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
	if ft and ft ~= "" then
		local prefix = M.get_by_filetype(ft)
		if prefix then
			return prefix
		end
	end

	-- 再降级：基于文件路径
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path and path ~= "" then
		local prefix = M.get_by_path(path)
		if prefix then
			return prefix
		end
	end

	-- 最终默认值
	return "//"
end

--- 根据文件路径获取注释前缀（处理未打开的文件）
--- @param path string 文件路径
--- @return string
function M.get_prefix_by_path(path)
	if not path or path == "" then
		return "//"
	end

	-- 尝试通过文件类型判断
	local ft = vim.filetype.match({ filename = path })
	if ft then
		local prefix = M.get_by_filetype(ft)
		if prefix then
			return prefix
		end
	end

	-- 降级到路径匹配
	return M.get_by_path(path) or "//"
end

--- 根据文件类型获取注释前缀
--- @param ft string 文件类型
--- @return string|nil
function M.get_by_filetype(ft)
	local ft_map = {
		-- 脚本语言
		lua = "--",
		python = "#",
		ruby = "#",
		perl = "#",
		sh = "#",
		bash = "#",
		zsh = "#",
		fish = "#",

		-- C 风格
		c = "//",
		cpp = "//",
		java = "//",
		javascript = "//",
		typescript = "//",
		javascriptreact = "//",
		typescriptreact = "//",
		go = "//",
		rust = "//",
		php = "//",
		swift = "//",
		kotlin = "//",
		scala = "//",
		dart = "//",

		-- 配置文件
		vim = '"',
		conf = "#",
		ini = ";",
		toml = "#",
		yaml = "#",
		json = "//", -- JSON 不支持注释，但有些工具支持
		xml = "<!--",
		html = "<!--",
		css = "/*",
		scss = "//",
		less = "//",

		-- 其他
		haskell = "--",
		sql = "--",
		lisp = ";",
		scheme = ";",
		clojure = ";",
		matlab = "%",
		tex = "%",
		markdown = "<!--",
	}

	return ft_map[ft]
end

--- 根据文件路径获取注释前缀
--- @param path string
--- @return string|nil
function M.get_by_path(path)
	if not path then
		return nil
	end

	-- Lua
	if path:match("%.lua$") then
		return "--"

	-- Python/Ruby/Shell
	elseif
		path:match("%.py$")
		or path:match("%.rb$")
		or path:match("%.sh$")
		or path:match("%.bash$")
		or path:match("%.zsh$")
		or path:match("%.fish$")
	then
		return "#"

	-- JavaScript/TypeScript
	elseif
		path:match("%.js$")
		or path:match("%.jsx$")
		or path:match("%.ts$")
		or path:match("%.tsx$")
		or path:match("%.mjs$")
		or path:match("%.cjs$")
	then
		return "//"

	-- C/C++/Java/Go/Rust
	elseif
		path:match("%.c$")
		or path:match("%.cpp$")
		or path:match("%.h$")
		or path:match("%.hpp$")
		or path:match("%.java$")
		or path:match("%.go$")
		or path:match("%.rs$")
		or path:match("%.swift$")
		or path:match("%.kt$")
		or path:match("%.scala$")
		or path:match("%.dart$")
	then
		return "//"

	-- PHP
	elseif path:match("%.php$") then
		return "//"

	-- Vim script
	elseif path:match("%.vim$") then
		return '"'

	-- HTML/XML
	elseif path:match("%.html$") or path:match("%.htm$") or path:match("%.xml$") or path:match("%.xhtml$") then
		return "<!--"

	-- CSS
	elseif path:match("%.css$") or path:match("%.scss$") or path:match("%.less$") or path:match("%.sass$") then
		return "/*"

	-- SQL
	elseif path:match("%.sql$") then
		return "--"

	-- LaTeX
	elseif path:match("%.tex$") then
		return "%"

	-- INI/Config
	elseif path:match("%.ini$") or path:match("%.cfg$") or path:match("%.conf$") then
		return ";"

	-- YAML/TOML
	elseif path:match("%.ya?ml$") or path:match("%.toml$") then
		return "#"

	-- Markdown
	elseif path:match("%.md$") or path:match("%.markdown$") then
		return "<!--"
	end

	return nil
end

--- 获取注释前缀和后缀（用于多行注释）
--- @param bufnr number|nil 缓冲区号
--- @return string, string 前缀, 后缀
function M.get_comment_parts(bufnr)
	bufnr = bufnr or 0
	local cs = vim.api.nvim_get_option_value("commentstring", { buf = bufnr })

	if cs and cs ~= "" then
		-- 尝试匹配前缀和后缀（如HTML的<!-- %s -->）
		local prefix, suffix = cs:match("^(.-)%%s(.*)$")
		if prefix and suffix then
			return prefix:gsub("%s+$", ""), suffix:gsub("^%s+", "")
		end
	end

	-- 默认返回单行注释前缀
	return M.get_prefix(bufnr), ""
end

--- 生成代码标记行
--- @param id string 任务ID
--- @param tag string|nil 标签，默认"TODO"
--- @param bufnr number|nil 缓冲区号
--- @return string
function M.generate_marker(id, tag, bufnr)
	local prefix = M.get_prefix(bufnr)
	tag = tag or "TODO"
	return string.format("%s %s:ref:%s", prefix, tag, id)
end

--- 生成多行注释标记
--- @param id string 任务ID
--- @param tag string|nil 标签，默认"TODO"
--- @param bufnr number|nil 缓冲区号
--- @return string, string 起始行, 结束行
function M.generate_multiline_marker(id, tag, bufnr)
	local prefix, suffix = M.get_comment_parts(bufnr)
	tag = tag or "TODO"

	if suffix and suffix ~= "" then
		-- 多行注释格式（如HTML）
		return string.format("%s %s:ref:%s ", prefix, tag, id), suffix
	else
		-- 单行注释格式
		return string.format("%s %s:ref:%s", prefix, tag, id), ""
	end
end

--- 检查缓冲区是否支持注释
--- @param bufnr number|nil 缓冲区号
--- @return boolean
function M.can_comment(bufnr)
	bufnr = bufnr or 0
	local cs = vim.api.nvim_get_option_value("commentstring", { buf = bufnr })
	return cs and cs ~= ""
end

--- 创建临时缓冲区获取注释前缀
--- @param path string 文件路径
--- @return string
function M.get_prefix_temp(path)
	if not path or path == "" then
		return "//"
	end

	local temp_bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(temp_bufnr, path)
	local prefix = M.get_prefix(temp_bufnr)
	vim.api.nvim_buf_delete(temp_bufnr, { force = true })

	return prefix
end

return M
