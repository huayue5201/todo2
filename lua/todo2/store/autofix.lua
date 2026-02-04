-- lua/todo2/store/autofix.lua
--- @module todo2.store.autofix
--- 自动修复模块

local M = {}

--- 设置自动修复
function M.setup_autofix()
	-- 创建自动命令组
	local group = vim.api.nvim_create_augroup("Todo2AutoFix", { clear = true })

	-- 文件保存时自动修复
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = {
			"*.md",
			"*.todo", -- TODO文件
			"*.rs",
			"*.lua", -- 代码文件
			"*.py",
			"*.js",
			"*.ts",
			"*.go",
			"*.java",
			"*.cpp",
		},
		callback = function(args)
			vim.schedule(function()
				M.fix_current_file(args.file)
			end)
		end,
	})

	-- 可选：启动时自动修复当前文件
	vim.schedule(function()
		local current_file = vim.fn.expand("%:p")
		if current_file and current_file ~= "" then
			M.fix_current_file(current_file)
		end
	end)
end

--- 修复当前文件中的链接
function M.fix_current_file(filepath)
	if not filepath or filepath == "" then
		return 0
	end

	-- 检查文件类型
	local ext = filepath:match("%.(%w+)$") or ""
	local is_todo = ext:match("md$") or ext:match("todo$")
	local is_code = ext:match("rs$")
		or ext:match("lua$")
		or ext:match("py$")
		or ext:match("js$")
		or ext:match("ts$")
		or ext:match("go$")
		or ext:match("java$")
		or ext:match("cpp$")
		or ext:match("c$")

	if not is_todo and not is_code then
		return 0
	end

	-- 调用链接修复
	local link = require("todo2.store.link")
	local result = link.fix_file_locations(filepath, is_todo and "todo" or "code")

	-- 显示结果
	if result.located > 0 then
		vim.notify(
			string.format("已修复 %d/%d 个链接的行号", result.located, result.total),
			vim.log.levels.INFO
		)
	end

	return result.located
end

return M
