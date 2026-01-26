-- lua/todo2/init.lua
--- @module todo2
--- @brief 主入口模块，使用统一的模块懒加载系统

local M = {}

---------------------------------------------------------------------
-- 统一的模块加载器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 默认配置
---------------------------------------------------------------------
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

		local store = module.get("store")
		if store and store.init then
			local success = store.init()
			if not success then
				vim.notify("存储模块初始化失败，部分功能可能不可用", vim.log.levels.ERROR)
			end
		end
	end

	-----------------------------------------------------------------
	-- link 模块配置
	-----------------------------------------------------------------
	if config.link then
		local link = module.get("link")
		if link.setup then
			link.setup(config.link)
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
	local keymaps = module.get("keymaps")
	keymaps.setup_global({
		link = module.get("link"),
		ui = module.get("ui"),
		manager = module.get("manager"),
		store = module.get("store"),
		config = config,
	})

	-----------------------------------------------------------------
	-- 代码状态渲染（初始化）
	-----------------------------------------------------------------
	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "lua", "rust", "go", "python", "javascript", "typescript", "c", "cpp" },
		callback = function(args)
			vim.schedule(function()
				local link = module.get("link")
				if link and link.render_code_status then
					link.render_code_status(args.buf)
				end
			end)
		end,
	})

	-----------------------------------------------------------------
	-- TODO 文件自动 conceal + refresh（保留，这是初始化操作）
	-----------------------------------------------------------------
	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "markdown" },
		callback = function(args)
			local bufname = vim.api.nvim_buf_get_name(args.buf)
			if bufname:match("%.todo%.md$") then
				vim.schedule(function()
					local ui = module.get("ui")
					if ui and ui.apply_conceal then
						ui.apply_conceal(args.buf)
					end
					-- 初始化时调用 refresh 是必要的
					if ui and ui.refresh then
						ui.refresh(args.buf)
					end
				end)
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufEnter", {
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

				local store = module.get("store")
				if not store or not store.get_link then
					return
				end

				-- 只在需要时重新定位链接（例如，首次打开文件时）
				local todo_links = store.find_todo_links_by_file(filepath)
				local code_links = store.find_code_links_by_file(filepath)

				for _, link in ipairs(todo_links) do
					store.get_todo_link(link.id, { force_relocate = true })
				end
				for _, link in ipairs(code_links) do
					store.get_code_link(link.id, { force_relocate = true })
				end
			end)
		end,
	})
end

---------------------------------------------------------------------
-- 工具函数：重新加载所有模块
---------------------------------------------------------------------
function M.reload_all()
	module.reload_all()
end

---------------------------------------------------------------------
-- 工具函数：模块加载状态
---------------------------------------------------------------------
function M.get_module_status()
	return module.get_status()
end

---------------------------------------------------------------------
-- 工具函数：打印模块状态（调试用）
---------------------------------------------------------------------
function M.print_module_status()
	module.print_status()
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

---------------------------------------------------------------------
-- 返回主模块
---------------------------------------------------------------------
return M
