-- lua/todo2/store/autofix.lua
-- 自动修复模块（集成位置修复 + 全量同步）

local M = {}

local module = require("todo2.module")

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------
local function get_file_type(filepath)
	if not filepath or filepath == "" then
		return "unknown"
	end
	local ext = filepath:match("%.(%w+)$") or ""
	if ext:match("md$") or ext:match("todo$") then
		return "todo"
	end
	if
		ext:match("rs$")
		or ext:match("lua$")
		or ext:match("py$")
		or ext:match("js$")
		or ext:match("ts$")
		or ext:match("go$")
		or ext:match("java$")
		or ext:match("cpp$")
		or ext:match("c$")
	then
		return "code"
	end
	return "unknown"
end

local function get_syncer()
	return module.get("link.syncer")
end

local function get_locator()
	return require("todo2.store.locator")
end

---------------------------------------------------------------------
-- 公共 API（仅保留被调用的函数）
---------------------------------------------------------------------
--- 全量同步当前文件
--- @param filepath string
--- @param file_type string|nil
--- @return boolean
function M.sync_current_file(filepath, file_type)
	file_type = file_type or get_file_type(filepath)
	local syncer = get_syncer()
	if not syncer then
		vim.notify("无法获取syncer模块，请检查配置", vim.log.levels.WARN)
		return false
	end
	if file_type == "todo" and syncer.sync_todo_links then
		syncer.sync_todo_links()
		return true
	elseif file_type == "code" and syncer.sync_code_links then
		syncer.sync_code_links()
		return true
	end
	return false
end

--- 修复文件中的链接位置
--- @param filepath string
--- @return table
function M.locate_file_links(filepath)
	local locator = get_locator()
	if not locator or not locator.locate_file_tasks then
		vim.notify("locator模块不可用", vim.log.levels.ERROR)
		return { located = 0, total = 0 }
	end
	return locator.locate_file_tasks(filepath)
end

--- 综合修复当前文件
--- @param filepath string|nil
--- @return table
function M.fix_current_file(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false, message = "无文件名" }
	end

	local file_type = get_file_type(filepath)
	if file_type == "unknown" then
		return { success = false, message = "不支持的文件类型" }
	end

	local config = require("todo2.store.config")
	local autofix_enabled = config.get("autofix.enabled")
	local sync_on_save = config.get("sync.on_save")
	local autofix_mode = config.get("autofix.mode") or "locate"

	local report = {
		file = filepath,
		type = file_type,
		autofix_enabled = autofix_enabled,
		sync_on_save = sync_on_save,
		located = 0,
		total = 0,
		synced = false,
		messages = {},
	}

	if sync_on_save then
		local ok = M.sync_current_file(filepath, file_type)
		report.synced = ok
		if ok then
			table.insert(report.messages, "全量同步完成")
		end
	end

	if autofix_enabled and (autofix_mode == "locate" or autofix_mode == "both") then
		local locator_result = M.locate_file_links(filepath)
		report.located = locator_result.located or 0
		report.total = locator_result.total or 0
		if report.located > 0 then
			table.insert(
				report.messages,
				string.format("修复了 %d/%d 个链接行号", report.located, report.total)
			)
		end
	end

	report.success = #report.messages > 0
	return report
end

--- 设置自动修复自动命令
function M.setup_autofix()
	local group = vim.api.nvim_create_augroup("Todo2AutoFix", { clear = true })
	local config = require("todo2.store.config")

	local autofix_enabled = config.get("autofix.enabled")
	if autofix_enabled then
		local patterns = config.get("autofix.file_types")
			or { "*.todo", "*.md", "*.lua", "*.rs", "*.py", "*.js", "*.ts", "*.go", "*.java", "*.cpp" }
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = patterns,
			callback = function(args)
				vim.schedule(function()
					M.fix_current_file(args.file)
				end)
			end,
		})
		vim.notify("已启用自动修复（位置修正）", vim.log.levels.INFO)
	end

	local sync_on_save = config.get("sync.on_save")
	if sync_on_save then
		local all_patterns = {
			"*.todo",
			"*.md",
			"*.rs",
			"*.lua",
			"*.py",
			"*.js",
			"*.ts",
			"*.go",
			"*.java",
			"*.cpp",
		}
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = all_patterns,
			callback = function(args)
				vim.schedule(function()
					M.sync_current_file(args.file)
				end)
			end,
		})
		vim.notify("已启用保存时全量同步", vim.log.levels.INFO)
	end
end

return M
