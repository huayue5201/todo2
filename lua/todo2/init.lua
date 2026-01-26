-- lua/todo2/init.lua
--- @module todo2
--- @brief 主入口模块，使用统一的模块懒加载系统

local M = {}

---------------------------------------------------------------------
-- 统一的模块加载器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 统一的配置管理
---------------------------------------------------------------------
local config_module = require("todo2.config")

---------------------------------------------------------------------
-- 插件初始化
---------------------------------------------------------------------
function M.setup(user_config)
	-- 初始化配置模块
	config_module.setup(user_config)

	-- 验证配置
	local valid, errors = config_module.validate()
	if not valid then
		for _, err in ipairs(errors) do
			vim.notify("配置错误: " .. err, vim.log.levels.ERROR)
		end
		return
	end

	-- 获取配置（用于向后兼容）
	local config = config_module.get()

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
	-- link 模块初始化（使用统一配置）
	-----------------------------------------------------------------
	local link = module.get("link")
	if link and link.setup then
		link.setup() -- link.setup 现在从 config 模块获取配置
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
		config = config, -- 传递完整配置用于向后兼容
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
			local store_config = config_module.get_store()
			if not store_config.auto_relocate then
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
-- 配置相关函数（提供向后兼容的接口）
---------------------------------------------------------------------
function M.get_config()
	return config_module.get()
end

function M.get_link_config()
	return config_module.get_link()
end

function M.get_store_config()
	return config_module.get_store()
end

function M.get_ui_config()
	return config_module.get_ui()
end

function M.get_conceal_config()
	return config_module.get_conceal()
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
