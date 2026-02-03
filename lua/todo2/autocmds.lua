-- lua/todo2/autocmds.lua
--- @module todo2.autocmds
--- @brief 自动命令管理模块

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 自动命令组
---------------------------------------------------------------------
local augroup = vim.api.nvim_create_augroup("Todo2", { clear = true })

---------------------------------------------------------------------
-- 初始化自动命令
---------------------------------------------------------------------
function M.setup()
	-- 代码状态渲染自动命令
	M.setup_code_status_autocmd()

	-- TODO 文件自动处理自动命令
	M.setup_todo_file_autocmd()

	-- 自动重新定位链接自动命令
	M.setup_autolocate_autocmd()
end

---------------------------------------------------------------------
-- 代码状态渲染自动命令
---------------------------------------------------------------------
function M.setup_code_status_autocmd()
	vim.api.nvim_create_autocmd("FileType", {
		group = augroup,
		pattern = { "lua", "rust", "go", "python", "javascript", "typescript", "c", "cpp" },
		callback = function(args)
			vim.schedule(function()
				local link = module.get("link")
				if link and link.render_code_status then
					link.render_code_status(args.buf)
				end
			end)
		end,
		desc = "在代码文件中渲染 TODO 状态",
	})
end

---------------------------------------------------------------------
-- TODO 文件自动处理自动命令
---------------------------------------------------------------------
function M.setup_todo_file_autocmd()
	vim.api.nvim_create_autocmd("FileType", {
		group = augroup,
		pattern = { "markdown" },
		callback = function(args)
			local bufname = vim.api.nvim_buf_get_name(args.buf)
			if bufname:match("%.todo%.md$") then
				vim.schedule(function()
					local ui = module.get("ui")
					if ui then
						-- 应用 conceal
						if ui.apply_conceal then
							ui.apply_conceal(args.buf)
						end
						-- 初始渲染
						if ui.refresh then
							ui.refresh(args.buf)
						end
					end
				end)
			end
		end,
		desc = "在 TODO 文件中应用 conceal 和初始渲染",
	})
end

---------------------------------------------------------------------
-- 自动重新定位链接自动命令
---------------------------------------------------------------------
function M.setup_autolocate_autocmd()
	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		pattern = "*",
		callback = function(args)
			-- 获取配置
			local config_module = require("todo2.config")
			-- 修改点：使用新的配置访问方式
			local auto_relocate = config_module.get("auto_relocate")
			if not auto_relocate then
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
				if not store then
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
		desc = "自动重新定位链接",
	})
end

---------------------------------------------------------------------
-- 清理自动命令
---------------------------------------------------------------------
function M.clear()
	vim.api.nvim_clear_autocmds({ group = augroup })
end

---------------------------------------------------------------------
-- 重新应用自动命令
---------------------------------------------------------------------
function M.reapply()
	M.clear()
	M.setup()
end

return M
