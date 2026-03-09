-- lua/todo2/config.lua (完整版)
--- @module todo2.config
--- 统一配置管理

local M = {}

---------------------------------------------------------------------
-- 默认配置
---------------------------------------------------------------------
M.defaults = {
	-- 核心配置
	link_default_window = "float",
	context_lines = 5, -- 上下文采集深度
	progress_style = 5, -- 进度条样式：1=只显示数字，2=数字+总数，3=百分比，4=简洁百分比，5=完整进度条
	show_status = true,
	auto_relocate = true,
	conceal_enable = true,

	-- 解析器配置（parser.lua 实际使用的）
	parser = {
		indent_width = 2, -- 缩进宽度（空格数）
		empty_line_reset = 1, -- 空行重置阈值：0=不重置，1=单个空行，2=连续2个空行
		context_split = false, -- 是否启用上下文分离
	},

	-- ⭐ 进度条样式配置
	progress_bar = {
		-- 样式类型：
		-- "full"    = ▰▰▰▱▱ 50% (5/10)
		-- "percent" = 50%
		-- "simple"  = (5/10)
		-- "compact" = 50% (5/10)
		style = "full",

		-- 进度条字符配置
		chars = {
			filled = "▰", -- 已完成部分字符
			empty = "▱", -- 未完成部分字符
			separator = " ", -- 分隔符
		},

		-- 进度条长度（字符数）
		length = {
			min = 5, -- 最小长度
			max = 20, -- 最大长度
		},

		-- 高亮组
		highlights = {
			done = "Todo2ProgressDone",
			todo = "Todo2ProgressTodo",
		},
	},

	-- 标签配置
	tags = {
		TODO = { icon = " ", id_icon = "🎯" },
		FIX = { icon = "󰁨 ", id_icon = "🐛" },
		NOTE = { icon = "󱓩 ", id_icon = "📃" },
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

	-- 归档区域标题配置
	archive_section = {
		title_format = "## Archived (%Y-%m)", -- 标题格式，可以使用 strftime 格式符
		auto_create = true, -- 是否自动创建归档区域
		position = "bottom", -- 归档区域的位置： "bottom" 或 "top"
	},

	file_template = {
		default_content = { -- 新文件默认内容
			"## Active",
			"",
		},
		add_active_section = true, -- 是否在创建时自动添加 Active 区域
		add_archive_section = false, -- 是否在创建时自动添加归档区域（会使用 archive_section 的配置）
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
-- ⭐ 进度条样式配置获取函数
---------------------------------------------------------------------

--- 获取进度条样式配置
--- @return table
function M.get_progress_bar_config()
	return M.get("progress_bar") or M.defaults.progress_bar
end

--- 获取进度条样式类型
--- @return string "full", "percent", "simple", "compact"
function M.get_progress_style()
	local bar_config = M.get_progress_bar_config()
	return bar_config.style or "full"
end

--- 获取进度条字符配置
--- @return table { filled, empty, separator }
function M.get_progress_chars()
	local bar_config = M.get_progress_bar_config()
	return bar_config.chars or M.defaults.progress_bar.chars
end

--- 获取进度条长度配置
--- @return table { min, max }
function M.get_progress_length()
	local bar_config = M.get_progress_bar_config()
	return bar_config.length or M.defaults.progress_bar.length
end

--- 获取进度条高亮组
--- @return table { done, todo }
function M.get_progress_highlights()
	local bar_config = M.get_progress_bar_config()
	return bar_config.highlights or M.defaults.progress_bar.highlights
end

--- 格式化进度条显示（供渲染模块使用）
--- @param progress table { percent, done, total }
--- @return table 虚拟文本部分
function M.format_progress_bar(progress)
	if not progress or progress.total <= 1 then
		return {}
	end

	local bar_config = M.get_progress_bar_config()
	local style = bar_config.style
	local chars = bar_config.chars
	local len_config = bar_config.length
	local highlights = bar_config.highlights

	local virt = {}

	if style == "full" then
		-- 完整进度条：▰▰▰▱▱ 50% (5/10)
		local len = math.max(len_config.min, math.min(len_config.max, progress.total))
		local filled = math.floor(progress.percent / 100 * len)

		-- 添加空格
		table.insert(virt, { " ", "Normal" })

		-- 添加已完成部分
		for _ = 1, filled do
			table.insert(virt, { chars.filled, highlights.done })
		end

		-- 添加未完成部分
		for _ = filled + 1, len do
			table.insert(virt, { chars.empty, highlights.todo })
		end

		-- 添加统计信息
		table.insert(virt, { " ", "Normal" })
		table.insert(virt, {
			string.format("%d%% (%d/%d)", progress.percent, progress.done, progress.total),
			highlights.done,
		})
	elseif style == "percent" then
		-- 只显示百分比：50%
		table.insert(virt, { " ", "Normal" })
		table.insert(virt, {
			string.format("%d%%", progress.percent),
			highlights.done,
		})
	elseif style == "simple" then
		-- 只显示数字： (5/10)
		table.insert(virt, { " ", "Normal" })
		table.insert(virt, {
			string.format("(%d/%d)", progress.done, progress.total),
			highlights.done,
		})
	elseif style == "compact" then
		-- 简洁版：50% (5/10)
		table.insert(virt, { " ", "Normal" })
		table.insert(virt, {
			string.format("%d%% (%d/%d)", progress.percent, progress.done, progress.total),
			highlights.done,
		})
	end

	return virt
end

---------------------------------------------------------------------
-- 归档区域配置获取函数
---------------------------------------------------------------------

--- 获取归档区域标题格式
--- @return string
function M.get_archive_title_format()
	local archive_config = M.get("archive_section") or {}
	return archive_config.title_format or "## Archived (%Y-%m)"
end

--- 是否自动创建归档区域
--- @return boolean
function M.is_archive_auto_create()
	local archive_config = M.get("archive_section") or {}
	-- 默认为 true
	if archive_config.auto_create == nil then
		return true
	end
	return archive_config.auto_create
end

--- 获取归档区域位置
--- @return string "bottom" 或 "top"
function M.get_archive_position()
	local archive_config = M.get("archive_section") or {}
	return archive_config.position or "bottom"
end

--- 生成归档区域标题（根据当前时间）
--- @param timestamp number|nil 时间戳，默认为当前时间
--- @return string
function M.generate_archive_title(timestamp)
	timestamp = timestamp or os.time()
	local format_str = M.get_archive_title_format()
	return os.date(format_str, timestamp)
end

--- 检查一行是否是归档区域标题
--- @param line string 要检查的行内容
--- @return boolean
function M.is_archive_section_line(line)
	local format_str = M.get_archive_title_format()

	-- 生成一个匹配模式
	-- 将 strftime 格式转换为简单的模式匹配
	-- 这里只处理常见的格式符
	local pattern = format_str
		:gsub("%%Y", "%d%d%d%d")
		:gsub("%%y", "%d%d")
		:gsub("%%m", "%d%d")
		:gsub("%%d", "%d%d")
		:gsub("%%H", "%d%d")
		:gsub("%%M", "%d%d")
		:gsub("%%S", "%d%d")
		:gsub("%%b", "%a%a%a")
		:gsub("%%B", "%a+")
		:gsub("%%a", "%a%a%a")
		:gsub("%%A", "%a+")
		:gsub("%%", "%%") -- 转义 % 符号

	-- 转义正则特殊字符
	pattern = pattern:gsub("([%(%)%.%[%]%+%-%*%?%^%$])", "%%%1")

	-- 将数字占位符替换为实际的正则
	pattern = pattern:gsub("%%d%d%d%d", "%d%d%d%d")
	pattern = pattern:gsub("%%d%d", "%d%d")
	pattern = pattern:gsub("%%a%a%a", "%a%a%a")
	pattern = pattern:gsub("%%a%+", "%a+")

	return line:match("^" .. pattern .. "$") ~= nil
end

--- 从归档区域标题中提取年月（如果有）
--- @param title string 标题行
--- @return string|nil 年月字符串 "YYYY-MM"
function M.extract_month_from_archive_title(title)
	local format_str = M.get_archive_title_format()
	-- 尝试提取年月信息（如果格式中包含 %Y 和 %m）
	local year, month = title:match("(%d%d%d%d)[^%d]*(%d%d)")
	if year and month then
		return year .. "-" .. month
	end
	return nil
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

--- 生成新文件的内容
--- @return table 文件内容行数组
function M.generate_new_file_content()
	local template = M.get("file_template") or M.defaults.file_template
	local content = vim.deepcopy(template.default_content or {})

	-- 如果需要自动添加 Active 区域
	if template.add_active_section then
		-- 如果内容为空或第一个不是标题，添加 Active 区域
		if #content == 0 or not content[1]:match("^##%s+Active") then
			table.insert(content, 1, "## Active")
			table.insert(content, 2, "")
		end
	end

	-- 如果需要自动添加归档区域
	if template.add_archive_section then
		local archive_title = M.generate_archive_title()
		table.insert(content, "")
		table.insert(content, archive_title)
		table.insert(content, "")
	end

	return content
end
return M
