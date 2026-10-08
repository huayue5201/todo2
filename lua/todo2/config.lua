-- lua/todo2/config.lua
--- 统一配置管理（纯配置模块，无业务逻辑）

local M = {}

---------------------------------------------------------------------
-- 默认配置（纯展示性配置）
---------------------------------------------------------------------
M.defaults = {
	-- 核心配置
	conceal_enable = true,
	-- 解析器配置（解析行为配置，不属于业务逻辑）
	parser = {
		indent_width = 2,
		empty_line_reset = 1,
		context_split = false,
	},

	-- 任务正文（任务行下方的缩进续行）
	description = {
		fold = true, -- 在 TODO 文件里默认折叠正文
		format_on_save = true, -- 保存时把正文缩进规整到列表项内容列
	},

	-- 代码文件里的任务渲染
	code_render = {
		-- "inline"：行内/行尾的虚拟文本；"above"：当前行上方的虚拟行；"below"：当前行下方的虚拟行
		position = "above",
		-- 同一代码行最多展示的任务数；超过时折叠为「代表任务 + +N」
		max_lines = 3,
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

	-- 复选框图标
	checkbox_icons = {
		todo = "◻",
		done = "✓", -- ☑
		archived = "📦",
	},

	-- 视图缩进图标
	viewer_icons = {
		indent = {
			top = "│ ",
			middle = "├─",
			last = "└─",
			ws = "  ",
		},
	},

	-- 视图（viewer）显示配置
	viewer_show_icons = true,
	viewer_show_child_count = true,
	viewer_file_header_style = "─ %s ──[ %d tasks ]",

	-- 任务树抽屉配置
	drawer = {
		position = "right", -- "right" | "bottom"（上下拆分可展示更多）
		width = 40, -- position = "right" 时的宽度
		height = 12, -- position = "bottom" 时的高度
		focus_on_jump = false, -- true 时 <CR> 跳转后焦点跟随到代码窗口
	},

	-- 循环状态（用户自定义）：顺序即循环顺序，第一个为默认状态。
	-- 每个状态：label 为存储值，icon 为图标，color 为状态色（作用于任务内容）。
	-- 状态轴只表达「进度」；任务类型请用标签（#fix / #refactor，见 utils/tags.lua）。
	status = {
		cycle = {
			{ label = "todo", icon = " ", color = "#51cf66" },
			{ label = "doing", icon = "▶ ", color = "#4dabf7" },
			{ label = "blocked", icon = "⛔ ", color = "#ff6b6b" },
		},
	},

	-- ⭐ 归档区域配置（仅展示性配置）
	archive_section = {
		title_prefix = "## Archived",
	},

	-- TODO 文件识别配置
	todo_files = {
		-- 后缀匹配（endswith，作用于完整路径）
		extensions = { ".todo.md", ".todo", ".todo.txt" },
		-- 精确文件名匹配（basename）
		filenames = { "todo.txt" },
		-- autocmd / globpath 使用的 glob 模式
		globs = { "*.todo.md", "*.todo", "*.todo.txt", "todo.txt" },
		-- 新建文件默认后缀
		default_ext = ".todo.md",
	},

	-- 新文件模板（已去掉行为配置，只保留展示内容）
	file_template = {
		default_content = {
			"## Active",
		},
	},

	-- 任务上下文（供 AI / 外部工具消费）
	ai = {
		include_code = true, -- 是否附带代码块正文
		include_ancestors = true, -- 是否附带祖先链
		include_children = 1, -- 子树层数：true=全部，数字=层数
		max_code_lines = 200, -- 代码正文最多取多少行（0 表示不限）
	},

	-- git 集成：把提交消息里的任务引用落成状态。
	-- 只开放「提交里怎么引用任务」这一真正的词汇表；扫描范围/元数据/缓存等机制固定。
	git = {
		enable = false, -- 总开关（:TodoGitSync! 可临时绕过）
		trigger = "manual", -- manual | on_open
		show_metadata = true, -- 在查看器 / 抽屉显示关联提交
		refs = {
			-- pattern 为 Lua 模式，取第 1 个捕获作为任务 id；
			-- status 直接引用 config.status.cycle 里的 label（completed 会写完成时间）。
			{ pattern = "[Tt]odo[:：]%s*([0-9a-z]+)", status = "completed" },
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

---@param key string|nil 配置键（支持点号路径，如 "parser.indent_width"）
---@param default any 当值为 nil 时返回的默认值
function M.get(key, default)
	if not key then
		return M.current
	end

	local value
	if not key:find("%.") then
		value = M.current[key]
	else
		local parts = vim.split(key, ".", { plain = true })
		value = M.current
		for _, part in ipairs(parts) do
			if type(value) == "table" then
				value = value[part]
			else
				value = nil
				break
			end
		end
	end

	if value == nil then
		return default
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
-- 状态
---------------------------------------------------------------------

--- 获取默认循环状态（第一个 label）
---@return string|nil
function M.get_default_status()
	local cycle = M.get("status.cycle") or {}
	return cycle[1] and cycle[1].label or nil
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
