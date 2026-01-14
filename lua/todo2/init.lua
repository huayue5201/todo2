-- lua/todo2/init.lua
local M = {}

-- 默认配置
local default_config = {
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
		},
	},
	store = {
		auto_relocate = true,
		verbose_logging = false,
		cleanup_days_old = 30,
	},
}

-- 配置存储
local config = vim.deepcopy(default_config)

-- 模块缓存（懒加载）
local modules = {
	core = nil,
	render = nil,
	link = nil,
	ui = nil,
	manager = nil,
	store = nil,
}

---------------------------------------------------------------------
-- 懒加载函数
---------------------------------------------------------------------
local function load_module(name)
	if not modules[name] then
		if name == "core" then
			modules[name] = require("todo2.core")
		elseif name == "render" then
			modules[name] = require("todo2.render")
		elseif name == "link" then
			modules[name] = require("todo2.link")
		elseif name == "ui" then
			modules[name] = require("todo2.ui")
		elseif name == "manager" then
			modules[name] = require("todo2.manager")
		elseif name == "store" then
			modules[name] = require("todo2.store")
		end
	end
	return modules[name]
end

-- 使用元表实现自动懒加载
setmetatable(M, {
	__index = function(self, key)
		if modules[key] then
			return modules[key]
		end

		if key == "core" or key == "render" or key == "link" or key == "ui" or key == "manager" or key == "store" then
			return load_module(key)
		end

		return nil
	end,
})

---------------------------------------------------------------------
-- 配置相关函数
---------------------------------------------------------------------
function M.get_config()
	return config
end

function M.get_link_config()
	return config.link or default_config.link
end

function M.get_store_config()
	return config.store or default_config.store
end

---------------------------------------------------------------------
-- 插件初始化
---------------------------------------------------------------------
function M.setup(user_config)
	-- 合并用户配置
	if user_config then
		config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user_config)
	end

	-----------------------------------------------------------------
	-- nvim-store3 初始化
	-----------------------------------------------------------------
	local has_nvim_store3, _ = pcall(require, "nvim-store3")
	if not has_nvim_store3 then
		vim.notify(
			[[todo2 需要 nvim-store3 插件支持。
请安装：https://github.com/yourname/nvim-store3
然后在 setup 后调用 require("nvim-store3").global()]],
			vim.log.levels.WARN
		)
	else
		require("nvim-store3").global({
			auto_encode = true,
			storage = {
				backend = "json",
				flush_delay = 1000,
			},
		})

		local store_module = load_module("store")
		if store_module and store_module.init then
			local success = store_module.init()
			if not success then
				vim.notify("存储模块初始化失败，部分功能可能不可用", vim.log.levels.ERROR)
			end
		end
	end

	-----------------------------------------------------------------
	-- link 模块配置
	-----------------------------------------------------------------
	if config.link then
		local link_module = load_module("link")
		if link_module.setup then
			link_module.setup(config.link)
		end
	end

	-----------------------------------------------------------------
	-- 高亮组
	-----------------------------------------------------------------
	vim.cmd([[
        highlight TodoCompleted guifg=#888888 gui=italic
        highlight TodoStrikethrough gui=strikethrough cterm=strikethrough
    ]])

	-----------------------------------------------------------------
	-- 全局按键（集中管理）
	-----------------------------------------------------------------
	local keymaps = require("todo2.keymaps")
	keymaps.setup_global({
		link = load_module("link"),
		ui = load_module("ui"),
		manager = load_module("manager"),
		store = load_module("store"),
		config = config,
	})

	-- 智能 <CR>：只有标签行触发 todo2 行为，否则保持默认
	vim.keymap.set("n", "<CR>", function()
		local line = vim.fn.getline(".")
		local tag, id = line:match("(%u+):ref:(%w+)")

		-- ⭐ 不是标签行 → 执行 Neovim 默认 <CR>
		if not id then
			return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
		end

		-----------------------------------------------------------------
		-- 1. 读取 TODO 链接（对齐 store 逻辑）
		-----------------------------------------------------------------
		local store = require("todo2.store")
		local link = store.get_todo_link(id, { force_relocate = true })
		if not link then
			vim.notify("未找到 TODO 链接: " .. id, vim.log.levels.ERROR)
			return
		end

		local todo_path = vim.fn.fnamemodify(link.path, ":p")
		local todo_line = link.line or 1

		if vim.fn.filereadable(todo_path) == 0 then
			vim.notify("TODO 文件不存在: " .. todo_path, vim.log.levels.ERROR)
			return
		end

		-----------------------------------------------------------------
		-- 2. 在对应 TODO buffer 中调用核心 toggle 逻辑
		--    等价于在 TODO 窗口里对该行执行一次切换：
		--    - 递归切换子任务
		--    - 父子联动由 core.sync_parent_child_state 负责
		--    - 内部会 silent write（你在 core.toggle_line 里已经写了）
		-----------------------------------------------------------------
		local core = require("todo2.core")

		-- 找到或创建 TODO buffer
		local todo_bufnr = vim.fn.bufnr(todo_path)
		if todo_bufnr == -1 then
			todo_bufnr = vim.fn.bufadd(todo_path)
			vim.fn.bufload(todo_bufnr)
		end

		-- 在该 buffer 的上下文中执行 toggle_line，保证所有逻辑一致
		vim.api.nvim_buf_call(todo_bufnr, function()
			core.toggle_line(todo_bufnr, todo_line)
		end)

		-----------------------------------------------------------------
		-- 3. 刷新代码侧渲染（当前 buffer）
		--    这里会重新读取 TODO 文件，触发你在 renderer.lua 里做的缓存逻辑，
		--    进度（3/7、百分比、进度条）都会自动更新。
		-----------------------------------------------------------------
		local renderer = require("todo2.link.renderer")
		renderer.render_code_status(0)

		-----------------------------------------------------------------
		-- 4. 不抢光标、不跳转窗口，只在代码侧“远程操作” TODO
		-----------------------------------------------------------------
	end, {
		desc = "智能切换 TODO 状态（对齐核心父子逻辑 + 虚拟文本进度刷新）",
	})

	-----------------------------------------------------------------
	-- 自动同步：代码文件
	-----------------------------------------------------------------
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = { "*.lua", "*.rs", "*.go", "*.ts", "*.js", "*.py", "*.c", "*.cpp" },
		callback = function()
			vim.defer_fn(function()
				local link_module = load_module("link")
				if link_module and link_module.sync_code_links then
					link_module.sync_code_links()
				end
			end, 0)
		end,
	})

	-----------------------------------------------------------------
	-- 自动同步：TODO 文件
	-----------------------------------------------------------------
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = { "*.todo.md", "*.todo", "todo.txt" },
		callback = function()
			vim.schedule(function()
				local link_module = load_module("link")
				if link_module and link_module.sync_todo_links then
					link_module.sync_todo_links()
				end
			end)
		end,
	})

	-----------------------------------------------------------------
	-- 代码状态渲染
	-----------------------------------------------------------------
	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "lua", "rust", "go", "python", "javascript", "typescript", "c", "cpp" },
		callback = function(args)
			vim.schedule(function()
				local link_module = load_module("link")
				if link_module and link_module.render_code_status then
					link_module.render_code_status(args.buf)
				end
			end)
		end,
	})

	-- 增量渲染：监听行变化
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		pattern = { "*.lua", "*.rs", "*.go", "*.ts", "*.js", "*.py", "*.c", "*.cpp" },
		callback = function(args)
			local bufnr = args.buf
			local row = vim.fn.line(".") - 1

			local renderer = require("todo2.link.renderer")
			renderer.render_line(bufnr, row)
		end,
	})
	-----------------------------------------------------------------
	-- TODO 文件自动 conceal + refresh
	-----------------------------------------------------------------
	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "markdown" },
		callback = function(args)
			local bufname = vim.api.nvim_buf_get_name(args.buf)
			if bufname:match("%.todo%.md$") then
				vim.schedule(function()
					local ui_module = load_module("ui")
					if ui_module.apply_conceal then
						ui_module.apply_conceal(args.buf)
					end
					if ui_module.refresh then
						ui_module.refresh(args.buf)
					end
				end)
			end
		end,
	})

	-----------------------------------------------------------------
	-- 自动重新定位链接
	-----------------------------------------------------------------
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "*",
		callback = function(args)
			if not config.store.auto_relocate then
				return
			end

			vim.schedule(function()
				-- 🔒 关键修复：检查 buffer 是否还存在
				if not vim.api.nvim_buf_is_valid(args.buf) then
					return
				end

				local filepath = vim.api.nvim_buf_get_name(args.buf)
				if not filepath or filepath == "" then
					return
				end

				local store_module = load_module("store")
				if not store_module or not store_module.get_link then
					return
				end

				local todo_links = store_module.find_todo_links_by_file(filepath)
				local code_links = store_module.find_code_links_by_file(filepath)

				for _, link in ipairs(todo_links) do
					store_module.get_todo_link(link.id, { force_relocate = true })
				end
				for _, link in ipairs(code_links) do
					store_module.get_code_link(link.id, { force_relocate = true })
				end
			end)
		end,
	})
end

---------------------------------------------------------------------
-- 工具函数：重新加载所有模块
---------------------------------------------------------------------
function M.reload_all()
	for name, _ in pairs(modules) do
		modules[name] = nil
		package.loaded["todo2." .. name] = nil
	end
	print("🔄 TODO 插件模块已重新加载")
end

---------------------------------------------------------------------
-- 工具函数：模块加载状态
---------------------------------------------------------------------
function M.get_module_status()
	local status = {}
	for name, module in pairs(modules) do
		status[name] = module ~= nil
	end
	return status
end

---------------------------------------------------------------------
-- 工具函数：检查依赖
---------------------------------------------------------------------
function M.check_dependencies()
	local deps = {
		nvim_store3 = pcall(require, "nvim-store3"),
	}

	local missing = {}
	for dep, ok in pairs(deps) do
		if not ok then
			table.insert(missing, dep)
		end
	end

	if #missing > 0 then
		return false, missing
	end

	return true
end

return M
