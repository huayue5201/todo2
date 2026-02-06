-- lua/todo2/autocmds.lua
--- @module todo2.autocmds
--- @brief 自动命令管理模块（修复自动保存事件冲突）

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

	-- ⭐ 修复：自动保存命令（修复事件触发）
	M.setup_autosave_autocmd_fixed()
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
-- ⭐ 修复：自动保存自动命令（正确触发事件）
---------------------------------------------------------------------
function M.setup_autosave_autocmd_fixed()
	-- 离开插入模式时保存并触发与Tab跳转相同的事件
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = augroup,
		pattern = "*.todo.md",
		callback = function()
			local bufnr = vim.api.nvim_get_current_buf()
			local bufname = vim.api.nvim_buf_get_name(bufnr)

			-- ⭐ 检查buffer是否有修改
			if not vim.api.nvim_buf_get_option(bufnr, "modified") then
				return -- 没有修改，不需要保存
			end

			local autosave = module.get("core.autosave")
			if autosave and autosave.flush then
				-- 立即保存
				local success = autosave.flush(bufnr)

				-- ⭐ 关键修改：使用与跳转相同的事件机制
				if success then
					-- 获取当前文件中的所有链接ID
					local store = module.get("store")
					local parser = module.get("core.parser")

					if store and parser then
						local todo_links = store.find_todo_links_by_file(bufname)
						local ids = {}

						for _, link in ipairs(todo_links) do
							if link.id then
								table.insert(ids, link.id)
							end
						end

						-- 如果找到链接，触发事件
						if #ids > 0 then
							local events_mod = module.get("core.events")
							if events_mod then
								events_mod.on_state_changed({
									source = "autosave", -- ⭐ 使用与跳转相同的source格式
									file = bufname,
									bufnr = bufnr,
									ids = ids,
									timestamp = os.time() * 1000,
								})
							end
						end
					end
				end
			end
		end,
		desc = "离开插入模式时保存TODO文件并触发刷新",
	})
end

---------------------------------------------------------------------
-- TODO 文件自动处理自动命令
---------------------------------------------------------------------
-- NOTE:ref:c78547
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
