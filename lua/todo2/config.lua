-- lua/todo2/config.lua
local M = {}

---------------------------------------------------------------------
-- 默认配置
---------------------------------------------------------------------
M.defaults = {
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
	return M.options
end

---------------------------------------------------------------------
-- 获取配置
---------------------------------------------------------------------
-- 获取全部配置
function M.get()
	return M.options
end

-- 获取特定部分配置
function M.get_section(section)
	return M.options[section]
end

-- 获取 Link 配置
function M.get_link()
	return M.options.link or M.defaults.link
end

-- 获取 Link Jump 配置
function M.get_link_jump()
	local link = M.get_link()
	return link.jump or M.defaults.link.jump
end

-- 获取 Link Preview 配置
function M.get_link_preview()
	local link = M.get_link()
	return link.preview or M.defaults.link.preview
end

-- 获取 Link Render 配置
function M.get_link_render()
	local link = M.get_link()
	return link.render or M.defaults.link.render
end

-- 获取 Store 配置
function M.get_store()
	return M.options.store or M.defaults.store
end

-- 获取 UI 配置
function M.get_ui()
	return M.options.ui or M.defaults.ui
end

-- 获取 Conceal 配置
function M.get_conceal()
	local ui = M.get_ui()
	return ui.conceal or M.defaults.ui.conceal
end

-- 获取浮动窗口配置
function M.get_float()
	local ui = M.get_ui()
	return ui.float or M.defaults.ui.float
end

---------------------------------------------------------------------
-- 更新配置（运行时）
---------------------------------------------------------------------
function M.update(section, key, value)
	if section and key then
		if value ~= nil then
			-- 更新特定键值
			if not M.options[section] then
				M.options[section] = {}
			end
			M.options[section][key] = value
		elseif type(key) == "table" then
			-- 批量更新某个 section
			M.options[section] = vim.tbl_deep_extend("force", M.options[section] or {}, key)
		end
	end
end

-- 重置为默认配置
function M.reset()
	M.options = vim.deepcopy(M.defaults)
	return M.options
end

---------------------------------------------------------------------
-- 验证配置
---------------------------------------------------------------------
function M.validate()
	local valid = true
	local errors = {}

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
