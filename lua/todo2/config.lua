-- lua/todo2/config.lua
local M = {}

---------------------------------------------------------------------
-- 默认配置
---------------------------------------------------------------------
M.defaults = {
	-- ⭐ 新增：解析器配置
	parser = {
		-- 每多少空格算一级缩进（支持 2 或 4）
		indent_width = 2,

		-- 缓存配置
		cache = {
			enabled = true,
			max_cache_files = 20,
			auto_invalidate_on_save = true,
		},

		-- 解析行为配置
		behavior = {
			strict_indent = true, -- 是否严格检查缩进（必须为 indent_width 的倍数）
			allow_mixed_indent = false, -- 是否允许混合缩进
			auto_fix_indent = true, -- 是否自动修正缩进错误
		},
	},

	-- Link 相关配置
	link = {
		jump = {
			keep_todo_split_when_jump = true,
			default_todo_window_mode = "float",
			reuse_existing_windows = true,
		},
		preview = {
			enabled = true,
			border = "rounded",
		},
		render = {
			show_status_in_code = true,
			-- 进度条样式：1=数字风(3/7), 3=百分比风 42%, 5=进度条风 [■■■□□]
			progress_style = 5,
			tags = {
				TODO = {
					icon = " ",
					hl = "TodoColor",
				},
				FIXME = {
					icon = "󰁨 ",
					hl = "FixmeColor",
				},
				NOTE = {
					icon = "󱓩 ",
					hl = "NoteColor",
				},
				IDEA = {
					icon = "󰅪 ",
					hl = "IdeaColor",
				},
			},
			status_icons = {
				todo = "☐",
				done = "✓",
			},
		},
	},

	-- Store 相关配置
	store = {
		auto_relocate = true,
		verbose_logging = false,
		cleanup_days_old = 30,
	},

	-- UI 相关配置
	ui = {
		-- 浮动窗口默认配置
		float = {
			width_ratio = 0.6,
			max_width = 140,
			min_height = 10,
			max_height = 30,
		},

		-- 隐藏功能配置
		conceal = {
			enable = true,
			level = 2,
			cursor = "ncv",
			symbols = {
				todo = "☐",
				done = "☑",
			},
		},

		-- 刷新配置
		refresh = {
			debounce_ms = 150,
		},
	},
}

---------------------------------------------------------------------
-- 用户配置存储
---------------------------------------------------------------------
M.options = {}

---------------------------------------------------------------------
-- 初始化配置
---------------------------------------------------------------------
function M.setup(user_config)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_config or {})

	-- ⭐ 验证配置并应用默认值
	M._validate_and_normalize()

	return M.options
end

---------------------------------------------------------------------
-- 配置验证与规范化
---------------------------------------------------------------------
function M._validate_and_normalize()
	-- 确保 parser 配置存在
	if not M.options.parser then
		M.options.parser = vim.deepcopy(M.defaults.parser)
	end

	-- 确保 indent_width 是有效的
	local indent_width = M.options.parser.indent_width
	if indent_width ~= 2 and indent_width ~= 4 then
		vim.notify(
			string.format("todo2: indent_width 必须是 2 或 4，当前值为 %d，使用默认值 2", indent_width),
			vim.log.levels.WARN
		)
		M.options.parser.indent_width = 2
	end

	-- 确保所有子配置都存在
	local parser = M.options.parser
	parser.cache = parser.cache or vim.deepcopy(M.defaults.parser.cache)
	parser.behavior = parser.behavior or vim.deepcopy(M.defaults.parser.behavior)

	-- 设置缓存限制
	if parser.cache.max_cache_files then
		parser.cache.max_cache_files = math.max(1, math.min(100, parser.cache.max_cache_files))
	end
end

---------------------------------------------------------------------
-- 通用配置获取函数
---------------------------------------------------------------------

-- 获取全部配置
function M.get()
	return M.options
end

-- 按路径获取配置（内部通用函数）
local function get_by_path(path)
	local parts = {}
	for part in path:gmatch("[^.]+") do
		table.insert(parts, part)
	end

	local result = M.options
	local default = M.defaults

	for _, part in ipairs(parts) do
		result = result and result[part]
		default = default and default[part]
	end

	return result or default
end

-- 使用通用函数创建所有获取函数
M.get_section = function(section)
	return M.options[section] or M.defaults[section]
end

M.get_parser = function()
	return get_by_path("parser")
end
M.get_indent_width = function()
	return get_by_path("parser.indent_width")
end
M.get_parser_cache = function()
	return get_by_path("parser.cache")
end
M.get_parser_behavior = function()
	return get_by_path("parser.behavior")
end
M.get_link = function()
	return get_by_path("link")
end
M.get_link_jump = function()
	return get_by_path("link.jump")
end
M.get_link_preview = function()
	return get_by_path("link.preview")
end
M.get_link_render = function()
	return get_by_path("link.render")
end
M.get_store = function()
	return get_by_path("store")
end
M.get_ui = function()
	return get_by_path("ui")
end
M.get_conceal = function()
	return get_by_path("ui.conceal")
end
M.get_float = function()
	return get_by_path("ui.float")
end

---------------------------------------------------------------------
-- 配置更新
---------------------------------------------------------------------
function M.update(section, updates, value)
	if not section then
		return
	end

	if type(updates) == "string" and value ~= nil then
		-- 单键值更新: update("section", "key", value)
		if not M.options[section] then
			M.options[section] = {}
		end
		M.options[section][updates] = value
	elseif type(updates) == "table" then
		-- 批量更新: update("section", {key1 = value1, key2 = value2})
		if not M.options[section] then
			M.options[section] = {}
		end
		M.options[section] = vim.tbl_deep_extend("force", M.options[section] or {}, updates)
	end

	M._validate_and_normalize()
end

-- 保持向后兼容
M.update_parser = function(config)
	M.update("parser", config)
end

-- 重置为默认配置
function M.reset()
	M.options = vim.deepcopy(M.defaults)
	M._validate_and_normalize()
	return M.options
end

---------------------------------------------------------------------
-- 验证配置
---------------------------------------------------------------------
function M.validate()
	local valid = true
	local errors = {}

	-- 验证 parser 配置
	local parser = M.get_parser()
	if parser.indent_width ~= 2 and parser.indent_width ~= 4 then
		table.insert(errors, "parser.indent_width must be 2 or 4")
		valid = false
	end

	if
		parser.cache
		and parser.cache.max_cache_files
		and (type(parser.cache.max_cache_files) ~= "number" or parser.cache.max_cache_files < 1)
	then
		table.insert(errors, "parser.cache.max_cache_files must be a positive number")
		valid = false
	end

	-- 验证 conceal 配置
	local conceal = M.get_conceal()
	if conceal.enable ~= nil and type(conceal.enable) ~= "boolean" then
		table.insert(errors, "conceal.enable must be boolean")
		valid = false
	end

	if conceal.symbols then
		if type(conceal.symbols.todo) ~= "string" or conceal.symbols.todo == "" then
			table.insert(errors, "conceal.symbols.todo must be a non-empty string")
			valid = false
		end
		if type(conceal.symbols.done) ~= "string" or conceal.symbols.done == "" then
			table.insert(errors, "conceal.symbols.done must be a non-empty string")
			valid = false
		end
	end

	-- 验证 link 配置
	local link = M.get_link()
	if link.render and link.render.progress_style then
		local valid_styles = { 1, 3, 5 }
		local is_valid = false
		for _, style in ipairs(valid_styles) do
			if link.render.progress_style == style then
				is_valid = true
				break
			end
		end
		if not is_valid then
			table.insert(errors, "link.render.progress_style must be 1, 3, or 5")
			valid = false
		end
	end

	return valid, errors
end

return M
