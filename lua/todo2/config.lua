-- lua/todo2/config.lua
local M = {}

M.defaults = {
	-- 核心配置
	indent_width = 2,

	-- 链接
	link_default_window = "float",

	-- 渲染
	progress_style = 5,
	show_status = true,

	-- TAG配置（每个标签有自己的id_icon）
	tags = {
		TODO = {
			icon = " ",
			id_icon = "󰳽", -- TODO的ID图标
			hl = "TodoColor",
		},
		FIX = {
			icon = "󰁨 ",
			id_icon = "󰳽", -- FIX的ID图标
			hl = "FixmeColor",
		},
		NOTE = {
			icon = "󱓩 ",
			id_icon = "󰳽", -- NOTE的ID图标
			hl = "NoteColor",
		},
		IDEA = {
			icon = "󰅪 ",
			id_icon = "󰳽", -- IDEA的ID图标
			hl = "IdeaColor",
		},
	},

	-- 查看器图标配置
	viewer_icons = {
		todo = "◻",
		done = "✓",
	},

	-- 存储
	auto_relocate = true,

	-- ⭐ 隐藏（Conceal）- 去掉了全局 id 图标
	conceal_enable = true,
	conceal_symbols = {
		todo = "☐", -- 未完成复选框
		done = "✓", -- 已完成复选框
		archived = "󱇮", -- 归档任务图标
		-- id 字段已移除，现在只使用 tags 中的 id_icon
	},

	-- 状态
	status_definitions = {
		normal = { icon = "", color = "#51cf66", label = "正常" },
		urgent = { icon = "󰚰", color = "#ff6b6b", label = "紧急" },
		waiting = { icon = "󱫖", color = "#ffd43b", label = "等待" },
		completed = { icon = "", color = "#868e96", label = "完成" },
	},
}

M.current = vim.deepcopy(M.defaults)

function M.setup(opts)
	if opts then
		M.current = vim.tbl_deep_extend("force", M.current, opts)
	end
	return M.current
end

function M.get(key)
	if not key then
		return M.current
	end

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

function M.update(key_or_table, value)
	if type(key_or_table) == "table" then
		M.current = vim.tbl_deep_extend("force", M.current, key_or_table)
	else
		M.current[key_or_table] = value
	end
end

return M
