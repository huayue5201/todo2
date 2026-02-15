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

	-- TAG配置
	tags = {
		TODO = { icon = " ", hl = "TodoColor" },
		FIX = { icon = "󰁨 ", hl = "FixmeColor" },
		NOTE = { icon = "󱓩 ", hl = "NoteColor" },
		IDEA = { icon = "󰅪 ", hl = "IdeaColor" },
	},

	-- 查看器图标配置
	viewer_icons = {
		todo = "◻",
		done = "✓",
	},

	-- 存储
	auto_relocate = true,

	-- ⭐ 隐藏（Conceal）
	conceal_enable = true,
	conceal_symbols = {
		todo = "☐", -- 未完成
		done = "✓", -- 已完成
		id = "󰌷", -- 任务ID
		archived = "󱇮", -- ⭐ 新增：归档任务图标
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
