-- lua/todo2/config.lua (精简版)
--- @module todo2.config
--- 统一配置管理

local M = {}

---------------------------------------------------------------------
-- 默认配置
---------------------------------------------------------------------
M.defaults = {
	-- 核心配置
	link_default_window = "float",
	context_lines = 3,
	progress_style = 5,
	show_status = true,
	auto_relocate = true,
	conceal_enable = true,

	-- 解析器配置（parser.lua 实际使用的）
	parser = {
		indent_width = 2, -- 缩进宽度（空格数）
		empty_line_reset = 1, -- 空行重置阈值：0=不重置，1=单个空行，2=连续2个空行
		context_split = false, -- 是否启用上下文分离
	},

	-- 标签配置
	-- TODO:ref:2c065e
	tags = {
		TODO = { icon = " ", id_icon = "󰳽" },
		FIX = { icon = "󰁨 ", id_icon = "󰳽" },
		NOTE = { icon = "󱓩 ", id_icon = "󰳽" },
		IDEA = { icon = "󰅪 ", id_icon = "󰳽" },
		DEBUG = { icon = " ", id_icon = "󰳽" },
	},

	-- 图标配置
	checkbox_icons = {
		todo = "◻",
		done = "✓",
		archived = "📦",
	},

	viewer_icons = {
		indent = {
			top = "│ ",
			middle = "├╴",
			last = "└╴",
			ws = "  ",
		},
		folded = "▶",
		unfolded = "▼",
		leaf = "○",
	},

	status_icons = {
		normal = { icon = "", color = "#51cf66", label = "正常" },
		urgent = { icon = "󰚰", color = "#ff6b6b", label = "紧急" },
		waiting = { icon = "󱫖", color = "#ffd43b", label = "等待" },
		completed = { icon = "", color = "#868e96", label = "完成" },
	},

	-- 存储相关配置
	verification = {
		enabled = true,
		auto_verify_interval = 86400,
		verify_on_file_save = true,
		batch_size = 50,
	},

	autofix = {
		enabled = true,
		mode = "locate",
		on_save = true,
		show_progress = true,
		debounce_ms = 500,
		throttle_ms = 5000,
		max_file_size_kb = 1024,
	},
}

---------------------------------------------------------------------
-- 当前配置
---------------------------------------------------------------------
M.current = vim.deepcopy(M.defaults)

---------------------------------------------------------------------
-- 公共API
---------------------------------------------------------------------

--- 初始化配置
--- @param opts table|nil 用户自定义配置
function M.setup(opts)
	if opts then
		M.current = vim.tbl_deep_extend("force", M.current, opts)
	end
	return M.current
end

--- 获取配置
--- @param key string|nil 配置键，支持点号访问，nil返回全部
--- @return any 配置值
function M.get(key)
	if not key then
		return M.current
	end

	-- 处理点号路径
	if not key:find("%.") then
		return M.current[key]
	end

	local parts = vim.split(key, ".", { plain = true })
	local value = M.current

	for _, part in ipairs(parts) do
		if type(value) == "table" then
			value = value[part]
		else
			return nil
		end
	end

	return value
end

--- 设置配置
--- @param key string 配置键，支持点号
--- @param value any 配置值
function M.set(key, value)
	local keys = vim.split(key, ".", { plain = true })
	local target = M.current

	for i = 1, #keys - 1 do
		local k = keys[i]
		if not target[k] or type(target[k]) ~= "table" then
			target[k] = {}
		end
		target = target[k]
	end

	local last_key = keys[#keys]
	target[last_key] = value

	M._save_config()
end

--- 更新配置（合并）
--- @param key_or_table string|table 配置键或配置表
--- @param value any 配置值（当第一个参数为键时使用）
function M.update(key_or_table, value)
	if type(key_or_table) == "table" then
		M.current = vim.tbl_deep_extend("force", M.current, key_or_table)
	else
		M.set(key_or_table, value)
	end
	M._save_config()
end

--- 重置为默认配置
function M.reset()
	M.current = vim.deepcopy(M.defaults)
	M._save_config()
end

--- 加载配置文件
function M.load()
	local config_path = M._get_config_path()
	if vim.fn.filereadable(config_path) == 1 then
		local content = vim.fn.readfile(config_path)
		if content and #content > 0 then
			local json_str = table.concat(content, "\n")
			local ok, loaded = pcall(vim.fn.json_decode, json_str)
			if ok and loaded and type(loaded) == "table" then
				M.current = vim.tbl_deep_extend("force", M.current, loaded)
			end
		end
	end
end

---------------------------------------------------------------------
-- 内部函数
---------------------------------------------------------------------
function M._get_config_path()
	local project_root = vim.fn.getcwd()
	return project_root .. "/.todo2/config.json"
end

function M._save_config()
	local config_path = M._get_config_path()
	local dir = vim.fn.fnamemodify(config_path, ":h")

	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	local json = vim.fn.json_encode(M.current)
	vim.fn.writefile({ json }, config_path)
end

---------------------------------------------------------------------
-- 解析器专用配置获取函数
---------------------------------------------------------------------

--- 获取空行重置阈值
--- @return number
function M.get_empty_line_reset()
	return M.get("parser.empty_line_reset") or 2
end

--- 是否启用上下文分离
--- @return boolean
function M.is_context_split_enabled()
	return M.get("parser.context_split") or false
end

--- 获取缩进宽度
--- @return number
function M.get_indent_width()
	return M.get("indent_width") or 2
end

---------------------------------------------------------------------
-- 其他辅助函数
---------------------------------------------------------------------

--- 将标签名转换为代码关键词
--- @param tag_name string 标签名
--- @return string 关键词
local function tag_to_keyword(tag_name)
	return "@" .. tag_name:lower()
end

--- 将代码关键词转换为标签名
--- @param keyword string 关键词
--- @return string|nil 标签名
local function keyword_to_tag(keyword)
	if not keyword or not keyword:match("^@") then
		return nil
	end
	return keyword:sub(2):upper()
end

--- 获取代码关键词列表
--- @return string[]
function M.get_code_keywords()
	local tags = M.get("tags") or {}
	local keywords = {}
	for tag_name, _ in pairs(tags) do
		table.insert(keywords, tag_to_keyword(tag_name))
	end
	table.sort(keywords)
	return keywords
end

--- 获取标签配置
--- @param tag_name_or_keyword string 标签名或关键词
--- @return table
function M.get_tag(tag_name_or_keyword)
	local tags = M.get("tags") or {}

	local tag_name = tag_name_or_keyword
	if tag_name_or_keyword:match("^@") then
		tag_name = keyword_to_tag(tag_name_or_keyword)
	end

	return tags[tag_name] or tags.TODO or {}
end

--- 获取复选框图标
function M.get_checkbox_icon(type)
	local icons = M.get("checkbox_icons") or M.defaults.checkbox_icons
	return icons[type] or (type == "todo" and "◻" or type == "done" and "✓" or "📦")
end

--- 获取状态图标
function M.get_status_icon(status)
	local icons = M.get("status_icons") or M.defaults.status_icons
	local icon_info = icons[status]
	return icon_info and icon_info.icon or ""
end

--- 获取防抖时间
--- @return number
function M.get_debounce_ms()
	return M.get("autofix.debounce_ms") or 500
end

--- 获取自动修复模式
--- @return string
function M.get_autofix_mode()
	return M.get("autofix.mode") or "locate"
end

return M
