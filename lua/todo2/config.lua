-- lua/todo2/config.lua
--- 统一配置管理（纯配置模块，无业务逻辑）

local M = {}

---------------------------------------------------------------------
-- 默认配置（纯展示性配置）
---------------------------------------------------------------------
M.defaults = {
	-- 核心配置
	conceal_enable = true,
	-- 行内 `@YYYY-MM-DD` 是否隐去，改由行尾元数据带展示（`● 11-02 · ↻10-30`）。
	-- 文件文本不变；光标所在行始终显形，方便查看/编辑真实值。
	conceal_due = true,
	-- 解析器配置（解析行为配置，不属于业务逻辑）
	parser = {
		indent_width = 2,
		empty_line_reset = 1,
		context_split = false,
	},

	-- 对账（.todo.md = 唯一真源，store 只是缓存 + 关系 + 描述）
	sync = {
		-- 启动时对项目内全部 TODO 文件做一次全量对账（reindex），
		-- 自愈机会式同步（BufRead/TextChanged/BufWritePre）漏事件造成的漂移。
		reconcile_on_start = true,
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
		-- above/below 虚拟行超出窗口时的处理方式：
		--   "trunc"（默认）：不随水平滚动，超出部分在右侧截断；
		--   "scroll"：nowrap 时随代码水平滚动，wrap 时等同 trunc；
		--   "auto"：由 'wrap' 决定；"wrap"：始终换行。
		virt_lines_overflow = "trunc",
	},

	-- 智能预览（:SmartPreview）
	preview = {
		-- 同一代码锚点关联多个任务时的安全上限（防止病态 fan-out 撑爆窗口数）；
		-- 常规情况下由几何自动决定平铺数量，不会因该值截断。
		max_blocks = 20,
	},

	-- 进度条样式配置（仅展示，不含渲染逻辑）
	progress_bar = {
		style = "full",
		chars = {
			filled = "▰",
			empty = "▱",
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
		expand_lines = true, -- true 时光标行超出抽屉宽度时用浮窗补全显示完整内容
	},

	-- 月历视图（:TodoCalendar）——只读展示带 @YYYY-MM-DD 的活跃任务
	calendar = {
		first_day_of_week = "monday", -- "monday" | "sunday"
		mark_icon = "●", -- 未完成任务的圆点（绿色 + 数字）
		done_icon = "○", -- 已完成任务的圆点（灰色 + 数字）
		winblend = 0, -- 浮窗半透明程度（0 = 不透明；>0 时会看到下层 buffer 的文字）
		show_completed = true, -- false 时月历只显示未完成任务（已完成的不计数、不上格）
	},

	-- 循环状态（用户自定义）：顺序即循环顺序，第一个为默认状态。
	-- 每个状态：label 为存储值，icon 为图标，color 为状态色（作用于任务内容）。
	-- 状态轴只表达「进度」；任务类型请用标签（#fix / #refactor，见 utils/tags.lua）。
	status = {
		cycle = {
			{ label = "todo", icon = " ", color = "#51cf66" },
			{ label = "doing", icon = "▶ ", color = "#f5c2e7" },
			{ label = "blocked", icon = "⛔ ", color = "#ff6b6b" },
		},
	},

	-- 命名筛选（:TodoFilter save NAME [...] 写入本表，:TodoFilter @NAME 应用）
	-- 每项：{ tags = {...}, status = "todo"|"active"|{...}, path = "src/" }（各项 AND，status 内 OR）
	filters = {},

	-- ⭐ 归档区域配置（仅展示性配置）
	archive_section = {
		title_prefix = "## Archived",
	},

	-- ⭐ 归档配置
	-- 归档 = 把任务组的行移入 TODO 文件里的 `## Archived (YYYY-MM)` 段并置为归档状态，
	-- 该段即唯一真相源；任务仍留在主 store（status=archived），可反归档。
	archive = {
		-- 是否允许归档未完成的任务组
		allow_unfinished = true,
		-- 已归档任务是否默认并入渲染/抽屉（会话内可用命令切换）
		include_in_render = false,
		-- 整棵子树已完成、且完成时间早于该天数的根任务组，自动归档（0 = 关闭）
		auto_after_days = 0,
	},

	-- ⭐ 孤儿任务回收（TODO 文件在插件之外被删除后的兜底）
	-- 任务失去全部存活位置（TODO 文件与代码锚点文件都不存在）时，先隔离到
	-- 独立桶 todo.orphan.<id>（数据完整、从活跃视图隐藏）；保留期内文件恢复
	-- 会自动还原，超期仍缺失才清除。只把 ENOENT 当作缺失，权限/IO 错误不算。
	orphan = {
		-- 是否启用自动回收（扫描 + 隔离；false 时仅 :TodoDoctor! 手动触发）
		enabled = true,
		-- 隔离保留天数：隔离超过该天数仍无文件恢复的孤儿任务将被清除（0 = 永不自动清除）
		retention_days = 30,
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
	M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), M._load_config(), opts or {})
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

---------------------------------------------------------------------
-- 内部函数
---------------------------------------------------------------------
function M._get_config_path()
	return vim.fn.getcwd() .. "/.todo2/config.json"
end

--- 需要持久化到项目文件的运行时状态（其余配置以 defaults + 用户 setup 为准）。
M.persist_keys = { "filters" }

--- 读取项目配置（仅 persist_keys；不存在或损坏时返回空表）。
---@return table
function M._load_config()
	local path = M._get_config_path()
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local ok, data = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(path), "\n"))
	if not ok or type(data) ~= "table" then
		return {}
	end
	local out = {}
	for _, key in ipairs(M.persist_keys) do
		if data[key] ~= nil then
			out[key] = data[key]
		end
	end
	return out
end

function M._save_config()
	local config_path = M._get_config_path()
	local dir = vim.fn.fnamemodify(config_path, ":h")

	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	local out = {}
	for _, key in ipairs(M.persist_keys) do
		if M.current[key] ~= nil then
			out[key] = M.current[key]
		end
	end
	vim.fn.writefile({ vim.fn.json_encode(out) }, config_path)
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

return M
