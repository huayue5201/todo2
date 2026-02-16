-- lua/todo2/config.lua
local M = {}

M.defaults = {
	-- 核心配置
	indent_width = 2,

	-- 链接
	link_default_window = "float",

	-- 上下文匹配配置
	context_lines = 3, -- 上下文行数，推荐使用奇数：1, 3, 5, 7

	-- 渲染
	progress_style = 5,
	show_status = true,

	-- TAG配置（每个标签有自己的id_icon）
	tags = {
		TODO = {
			icon = " ",
			id_icon = "󰳽",
		},
		FIX = {
			icon = "󰁨 ",
			id_icon = "󰳽",
		},
		NOTE = {
			icon = "󱓩 ",
			id_icon = "󰳽",
		},
		IDEA = {
			icon = "󰅪 ",
			id_icon = "󰳽",
		},
		DEBUG = {
			icon = " ",
			id_icon = "󰳽",
		},
	},

	-- 统一复选框图标配置（所有地方都用这个）
	checkbox_icons = {
		todo = "◻", -- 未完成
		done = "✓", -- 已完成
		archived = "📦", -- 已归档
	},

	-- 查看器图标配置（树形结构相关）
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

	-- 状态图标
	status_icons = {
		normal = { icon = "", color = "#51cf66", label = "正常" },
		urgent = { icon = "󰚰", color = "#ff6b6b", label = "紧急" },
		waiting = { icon = "󱫖", color = "#ffd43b", label = "等待" },
		completed = { icon = "", color = "#868e96", label = "完成" },
	},

	-- 存储
	auto_relocate = true,

	-- 隐藏（Conceal）- 只控制是否启用
	conceal_enable = true,
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

-- 辅助函数：获取复选框图标
function M.get_checkbox_icon(type)
	local icons = M.get("checkbox_icons") or { todo = "◻", done = "✓", archived = "📦" }
	return icons[type] or (type == "todo" and "◻" or type == "done" and "✓" or "📦")
end

-- 辅助函数：获取状态图标
function M.get_status_icon(status)
	local icons = M.get("status_icons") or {}
	local icon_info = icons[status]
	return icon_info and icon_info.icon or ""
end

-- 辅助函数：获取状态标签
function M.get_status_label(status)
	local icons = M.get("status_icons") or {}
	local icon_info = icons[status]
	return icon_info and icon_info.label or ""
end

return M
