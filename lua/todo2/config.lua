-- lua/todo2/config.lua
--- 统一配置管理（纯配置模块，无业务逻辑）

local M = {}

---------------------------------------------------------------------
-- 默认配置（纯展示性配置）
---------------------------------------------------------------------
M.defaults = {
	-- 核心配置
	show_status = true,
	auto_relocate = true,
	conceal_enable = true,
	-- 解析器配置（解析行为配置，不属于业务逻辑）
	parser = {
		indent_width = 2,
		empty_line_reset = 1,
		context_split = false,
	},

	-- 进度条样式配置（仅展示，不含渲染逻辑）
	progress_bar = {
		style = "full",
		chars = {
			filled = "▰",
			empty = "▱",
			separator = " ",
		},
		length = {
			min = 5,
			max = 20,
		},
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
		TEST = { icon = "󰇉 ", id_icon = "🗜️" },
	},

	-- 复选框图标
	checkbox_icons = {
		todo = "◻",
		done = "✔",
		archived = "📦",
	},

	-- 视图缩进图标
	viewer_icons = {
		indent = {
			top = "│ ",
			middle = "├╴",
			last = "└╴",
			ws = "  ",
		},
	},

	-- 状态图标
	status_icons = {
		normal = { icon = "", color = "#51cf66", label = "正常" },
		urgent = { icon = "󰚰", color = "#ff6b6b", label = "紧急" },
		waiting = { icon = "󱫖", color = "#ffd43b", label = "等待" },
		completed = { icon = "", color = "#868e96", label = "完成" },
	},

	-- ⭐ 归档区域配置（仅展示性配置）
	archive_section = {
		title_prefix = "## Archived",
	},

	-- 新文件模板（已去掉行为配置，只保留展示内容）
	file_template = {
		default_content = {
			"## Active",
		},
	},
}

---------------------------------------------------------------------
-- 当前配置
---------------------------------------------------------------------
M.current = vim.deepcopy(M.defaults)

---------------------------------------------------------------------
-- 公共 API
---------------------------------------------------------------------

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

	target[keys[#keys]] = value
	M._save_config()
end

function M.update(key_or_table, value)
	if type(key_or_table) == "table" then
		M.current = vim.tbl_deep_extend("force", M.current, key_or_table)
	else
		M.set(key_or_table, value)
	end
	M._save_config()
end

function M.reset()
	M.current = vim.deepcopy(M.defaults)
	M._save_config()
end

function M.load()
	local config_path = M._get_config_path()
	if vim.fn.filereadable(config_path) == 1 then
		local content = vim.fn.readfile(config_path)
		if content and #content > 0 then
			local ok, loaded = pcall(vim.fn.json_decode, table.concat(content, "\n"))
			if ok and type(loaded) == "table" then
				M.current = vim.tbl_deep_extend("force", M.current, loaded)
			end
		end
	end
end

---------------------------------------------------------------------
-- 内部函数
---------------------------------------------------------------------
function M._get_config_path()
	return vim.fn.getcwd() .. "/.todo2/config.json"
end

function M._save_config()
	local config_path = M._get_config_path()
	local dir = vim.fn.fnamemodify(config_path, ":h")

	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	vim.fn.writefile({ vim.fn.json_encode(M.current) }, config_path)
end

---------------------------------------------------------------------
-- 标签 / 图标 / 状态
---------------------------------------------------------------------

function M.get_status_icon(status)
	local icons = M.get("status_icons") or M.defaults.status_icons
	return (icons[status] or {}).icon or ""
end

---------------------------------------------------------------------
-- 文件模板
---------------------------------------------------------------------
function M.generate_new_file_content()
	local template = M.get("file_template") or M.defaults.file_template
	local content = vim.deepcopy(template.default_content or {})

	if #content == 0 or not content[1]:match("^##%s+Active") then
		table.insert(content, 1, "## Active")
		table.insert(content, 2, "")
	end

	return content
end

return M
