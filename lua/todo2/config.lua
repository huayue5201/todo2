-- lua/todo2/config.lua
--- @module todo2.config
--- 统一配置管理（合并根配置和存储配置）

local M = {}

---------------------------------------------------------------------
-- 默认配置
---------------------------------------------------------------------
M.defaults = {
	-- ==================== 核心配置 ====================
	indent_width = 2,
	link_default_window = "float",
	context_lines = 3, -- 上下文行数，推荐使用奇数：1, 3, 5, 7
	progress_style = 5,
	show_status = true,
	auto_relocate = true,
	conceal_enable = true,

	-- ==================== TAG配置（单一数据源）====================
	-- 标签名就是代码中的关键词（自动转换为 @标签名 小写）
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

	-- ==================== 图标配置 ====================
	checkbox_icons = {
		todo = "◻", -- 未完成
		done = "✓", -- 已完成
		archived = "📦", -- 已归档
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

	-- ==================== 存储相关配置 ====================
	-- 验证配置（仅行号验证与状态标记，不负责增删）
	verification = {
		enabled = true,
		auto_verify_interval = 86400, -- 24小时
		verify_on_file_save = true, -- 文件保存时验证行号
		batch_size = 50,
	},

	-- 自动修复配置
	autofix = {
		enabled = false, -- 默认关闭
		mode = "locate", -- locate / sync / both
		on_save = true,
		show_progress = true,
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

	-- 导航到目标位置
	for i = 1, #keys - 1 do
		local k = keys[i]
		if not target[k] or type(target[k]) ~= "table" then
			target[k] = {}
		end
		target = target[k]
	end

	-- 设置值
	local last_key = keys[#keys]
	target[last_key] = value

	-- 保存到文件（可选）
	M._save_config()
end

--- 更新配置（合并）
--- @param updates table 更新的配置
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

	-- 确保目录存在
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	local json = vim.fn.json_encode(M.current)
	vim.fn.writefile({ json }, config_path)
end

---------------------------------------------------------------------
-- 派生配置函数（从 tags 自动生成）
---------------------------------------------------------------------

--- 将标签名转换为代码关键词
--- @param tag_name string 标签名，如 "TODO"
--- @return string 关键词，如 "@todo"
local function tag_to_keyword(tag_name)
	return "@" .. tag_name:lower()
end

--- 将代码关键词转换为标签名
--- @param keyword string 关键词，如 "@todo"
--- @return string|nil 标签名，如 "TODO"
local function keyword_to_tag(keyword)
	if not keyword or not keyword:match("^@") then
		return nil
	end
	return keyword:sub(2):upper()
end

--- 获取代码关键词列表
--- @return string[] 代码关键词列表
function M.get_code_keywords()
	local tags = M.get("tags") or {}
	local keywords = {}
	for tag_name, _ in pairs(tags) do
		table.insert(keywords, tag_to_keyword(tag_name))
	end
	-- 排序
	table.sort(keywords)
	return keywords
end

--- 通过关键词查找标签名
--- @param keyword string 代码关键词，如 "@todo"
--- @return string|nil 标签名，如 "TODO"
function M.get_tag_name_by_keyword(keyword)
	return keyword_to_tag(keyword)
end

--- 通过标签名获取关键词
--- @param tag_name string 标签名，如 "TODO"
--- @return string 关键词，如 "@todo"
function M.get_keyword_by_tag_name(tag_name)
	return tag_to_keyword(tag_name)
end

--- 获取标签配置
--- @param tag_name_or_keyword string 标签名或关键词
--- @return table 标签配置
function M.get_tag(tag_name_or_keyword)
	local tags = M.get("tags") or {}

	-- 如果是关键词，先转换为标签名
	local tag_name = tag_name_or_keyword
	if tag_name_or_keyword:match("^@") then
		tag_name = keyword_to_tag(tag_name_or_keyword)
	end

	return tags[tag_name] or tags.TODO or {}
end

---------------------------------------------------------------------
-- 其他辅助函数
---------------------------------------------------------------------

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

--- 获取状态标签
function M.get_status_label(status)
	local icons = M.get("status_icons") or M.defaults.status_icons
	local icon_info = icons[status]
	return icon_info and icon_info.label or ""
end

return M
