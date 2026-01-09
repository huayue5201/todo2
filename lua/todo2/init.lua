-- lua/todo2/init.lua
local M = {}

-- 默认配置
local default_config = {
	link = {
		jump = {
			keep_todo_split_when_jump = true, -- 分屏TODO跳转时是否保持分屏窗口
			default_todo_window_mode = "float", -- 默认打开TODO的窗口模式: "float" | "split" | "vsplit"
			reuse_existing_windows = true, -- 是否复用已存在的窗口
		},
		preview = {
			enabled = true, -- 是否启用预览功能
			border = "rounded", -- 预览窗口边框样式
		},
		render = {
			show_status_in_code = true, -- 在代码中显示TODO状态
		},
	},
	store = {
		auto_relocate = true, -- 是否自动重新定位链接
		verbose_logging = false, -- 详细日志
		cleanup_days_old = 30, -- 清理多少天前的数据
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

		-- 尝试懒加载
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
	-- 合并用户配置和默认配置
	if user_config then
		config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user_config)
	end

	-- 检查nvim-store3依赖
	local has_nvim_store3, _ = pcall(require, "nvim-store3")
	if not has_nvim_store3 then
		vim.notify(
			[[todo2 需要 nvim-store3 插件支持。
请安装：https://github.com/yourname/nvim-store3
然后在 setup 后调用 require("nvim-store3").global()]],
			vim.log.levels.WARN
		)
		-- 继续初始化其他模块，但存储功能将不可用
	else
		-- 初始化 nvim-store3
		require("nvim-store3").global({
			auto_encode = true,
			storage = {
				backend = "json",
				flush_delay = 1000,
			},
		})

		-- 初始化存储模块
		local store_module = load_module("store")
		if store_module and store_module.init then
			local success = store_module.init()
			if not success then
				vim.notify("存储模块初始化失败，部分功能可能不可用", vim.log.levels.ERROR)
			end
		end
	end

	-------------------------------------------------------------------
	-- 应用配置到 link 模块
	-------------------------------------------------------------------
	if config.link then
		local link_module = load_module("link")
		if link_module.setup then
			link_module.setup(config.link)
		end
	end

	-------------------------------------------------------------------
	-- 高亮组
	-------------------------------------------------------------------
	vim.cmd([[
        highlight TodoCompleted guifg=#888888 gui=italic
        highlight TodoStrikethrough gui=strikethrough cterm=strikethrough
    ]])

	-------------------------------------------------------------------
	-- 全局按键映射
	-------------------------------------------------------------------

	-- 创建链接
	vim.keymap.set("n", "<leader>tda", function()
		local link_module = load_module("link")
		if link_module and link_module.create_link then
			link_module.create_link()
		end
	end, { desc = "创建代码→TODO 链接" })

	-- 动态跳转
	vim.keymap.set("n", "gj", function()
		local link_module = load_module("link")
		if link_module and link_module.jump_dynamic then
			link_module.jump_dynamic()
		end
	end, { desc = "动态跳转 TODO <-> 代码" })

	-- 双链标记管理
	vim.keymap.set("n", "<leader>tdq", function()
		local manager_module = load_module("manager")
		if manager_module and manager_module.show_project_links_qf then
			manager_module.show_project_links_qf()
		end
	end, { desc = "显示所有双链标记 (QuickFix)" })

	vim.keymap.set("n", "<leader>tdl", function()
		local manager_module = load_module("manager")
		if manager_module and manager_module.show_buffer_links_loclist then
			manager_module.show_buffer_links_loclist()
		end
	end, { desc = "显示当前缓冲区双链标记 (LocList)" })

	vim.keymap.set("n", "<leader>tdr", function()
		local manager_module = load_module("manager")
		if manager_module and manager_module.fix_orphan_links_in_buffer then
			manager_module.fix_orphan_links_in_buffer()
		end
	end, { desc = "修复当前缓冲区孤立的标记" })

	vim.keymap.set("n", "<leader>tdw", function()
		local manager_module = load_module("manager")
		if manager_module and manager_module.show_stats then
			manager_module.show_stats()
		end
	end, { desc = "显示双链标记统计" })

	-------------------------------------------------------------------
	-- 悬浮预览
	-------------------------------------------------------------------
	vim.keymap.set("n", "<leader>tk", function()
		local link_module = load_module("link")
		if not link_module then
			return
		end

		local line = vim.fn.getline(".")

		if line:match("TODO:ref:(%w+)") then
			if link_module.preview_todo then
				link_module.preview_todo()
			end
		elseif line:match("{#(%w+)}") then
			if link_module.preview_code then
				link_module.preview_code()
			end
		else
			vim.lsp.buf.hover()
		end
	end, { desc = "预览 TODO 或代码" })

	-------------------------------------------------------------------
	-- TODO 文件管理
	-------------------------------------------------------------------

	-- 浮窗打开
	vim.keymap.set("n", "<leader>tdo", function()
		local ui_module = load_module("ui")
		if ui_module and ui_module.select_todo_file then
			ui_module.select_todo_file("current", function(choice)
				if choice then
					ui_module.open_todo_file(choice.path, "float", 1, { enter_insert = false })
				end
			end)
		end
	end, { desc = "TODO: 浮窗打开" })

	-- 水平分割打开
	vim.keymap.set("n", "<leader>tds", function()
		local ui_module = load_module("ui")
		if ui_module and ui_module.select_todo_file then
			ui_module.select_todo_file("current", function(choice)
				if choice then
					ui_module.open_todo_file(choice.path, "split", 1, {
						enter_insert = false,
						split_direction = "horizontal",
					})
				end
			end)
		end
	end, { desc = "TODO: 水平分割打开" })

	-- 垂直分割打开
	vim.keymap.set("n", "<leader>tdv", function()
		local ui_module = load_module("ui")
		if ui_module and ui_module.select_todo_file then
			ui_module.select_todo_file("current", function(choice)
				if choice then
					ui_module.open_todo_file(choice.path, "split", 1, {
						enter_insert = false,
						split_direction = "vertical",
					})
				end
			end)
		end
	end, { desc = "TODO: 垂直分割打开" })

	-- 编辑模式打开
	vim.keymap.set("n", "<leader>tde", function()
		local ui_module = load_module("ui")
		if ui_module and ui_module.select_todo_file then
			ui_module.select_todo_file("current", function(choice)
				if choice then
					ui_module.open_todo_file(choice.path, "edit", 1, { enter_insert = false })
				end
			end)
		end
	end, { desc = "TODO: 编辑模式打开" })

	-- 创建 TODO 文件
	vim.keymap.set("n", "<leader>tdn", function()
		local ui_module = load_module("ui")
		if ui_module and ui_module.create_todo_file then
			ui_module.create_todo_file()
		end
	end, { desc = "TODO: 创建文件" })

	-- 删除 TODO 文件
	vim.keymap.set("n", "<leader>tdd", function()
		local ui_module = load_module("ui")
		if ui_module and ui_module.select_todo_file then
			ui_module.select_todo_file("current", function(choice)
				if choice and ui_module.delete_todo_file then
					ui_module.delete_todo_file(choice.path)
				end
			end)
		end
	end, { desc = "TODO: 删除文件" })

	-------------------------------------------------------------------
	-- 存储维护工具
	-------------------------------------------------------------------
	vim.keymap.set("n", "<leader>tdc", function()
		local store_module = load_module("store")
		if store_module and store_module.cleanup then
			local days = config.store.cleanup_days_old or 30
			local cleaned = store_module.cleanup(days)
			if cleaned then
				vim.notify(string.format("清理了 %d 条过期数据", cleaned), vim.log.levels.INFO)
			end
		end
	end, { desc = "清理过期存储数据" })

	vim.keymap.set("n", "<leader>tdv", function()
		local store_module = load_module("store")
		if store_module and store_module.validate_all_links then
			local results = store_module.validate_all_links({
				verbose = config.store.verbose_logging,
				force = false,
			})
			if results and results.summary then
				vim.notify(results.summary, vim.log.levels.INFO)
			end
		end
	end, { desc = "验证所有链接" })

	-------------------------------------------------------------------
	-- 自动同步：代码文件
	-------------------------------------------------------------------
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = { "*.lua", "*.rs", "*.go", "*.ts", "*.js", "*.py", "*.c", "*.cpp" },
		callback = function(args)
			vim.defer_fn(function()
				local link_module = load_module("link")
				if link_module and link_module.sync_code_links then
					link_module.sync_code_links()
				end
			end, 0)
		end,
	})

	-------------------------------------------------------------------
	-- 自动同步：TODO 文件
	-------------------------------------------------------------------
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

	-- 标记状态渲染
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

	-- TODO文件自动应用conceal和刷新
	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "markdown" },
		callback = function(args)
			local bufname = vim.api.nvim_buf_get_name(args.buf)
			if bufname:match("%.todo%.md$") then
				vim.schedule(function()
					local ui_module = load_module("ui")
					if ui_module and ui_module.apply_conceal then
						ui_module.apply_conceal(args.buf)
					end
					if ui_module and ui_module.refresh then
						ui_module.refresh(args.buf)
					end
				end)
			end
		end,
	})

	-- 自动重新定位链接（如果配置开启）
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "*",
		callback = function(args)
			if config.store and config.store.auto_relocate then
				vim.schedule(function()
					local filepath = vim.api.nvim_buf_get_name(args.buf)
					if filepath and filepath ~= "" then
						-- 触发存储模块的自动重新定位
						local store_module = load_module("store")
						if store_module and store_module.get_link then
							-- 这里会触发自动重新定位逻辑
							local todo_links = store_module.find_todo_links_by_file(filepath)
							local code_links = store_module.find_code_links_by_file(filepath)

							-- 自动验证这些链接
							for _, link in ipairs(todo_links) do
								store_module.get_todo_link(link.id, { force_relocate = true })
							end
							for _, link in ipairs(code_links) do
								store_module.get_code_link(link.id, { force_relocate = true })
							end
						end
					end
				end)
			end
		end,
	})

	vim.notify("TODO插件初始化完成", vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- 工具函数：重新加载所有模块（用于调试）
---------------------------------------------------------------------
function M.reload_all()
	-- 清除所有缓存的模块
	for name, _ in pairs(modules) do
		modules[name] = nil
		package.loaded["todo2." .. name] = nil
	end

	print("🔄 TODO 插件模块已重新加载")
end

---------------------------------------------------------------------
-- 工具函数：获取模块加载状态
---------------------------------------------------------------------
function M.get_module_status()
	local status = {}
	for name, module in pairs(modules) do
		status[name] = module ~= nil
	end
	return status
end

-- 工具函数：检查依赖
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
