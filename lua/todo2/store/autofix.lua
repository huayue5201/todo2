-- lua/todo2/store/autofix.lua
-- 自动修复模块（仅保留必要方法）

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local index = require("todo2.store.index")
local config = require("todo2.store.config")
local parser = require("todo2.core.parser")
local format = require("todo2.utils.format")

---------------------------------------------------------------------
-- 核心：TODO文件全量同步
---------------------------------------------------------------------
function M.sync_todo_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false }
	end

	local _, _, id_to_task = parser.parse_file(filepath, true)
	local report = { created = 0, updated = 0, deleted = 0 }

	-- 获取现有链接
	local existing = {}
	for _, obj in ipairs(index.find_todo_links_by_file(filepath)) do
		existing[obj.id] = obj
	end

	-- 处理新增和更新
	for id, task in pairs(id_to_task or {}) do
		if existing[id] then
			local old = existing[id]
			local dirty = false

			if old.line ~= task.line_num then
				old.line = task.line_num
				dirty = true
			end
			if old.content ~= task.content then
				old.content = task.content
				old.content_hash = locator.calculate_content_hash(task.content)
				dirty = true
			end
			if old.tag ~= (task.tag or "TODO") then
				old.tag = task.tag or "TODO"
				dirty = true
			end
			if old.status ~= task.status then
				old.status = task.status
				if task.status == "completed" then
					old.completed_at = os.time()
				elseif task.status == "archived" then
					old.archived_at = os.time()
				else
					old.completed_at, old.archived_at = nil, nil
				end
				dirty = true
			end

			if dirty then
				old.updated_at = os.time()
				store.set_key("todo.links.todo." .. id, old)
				report.updated = report.updated + 1
			end
			existing[id] = nil
		else
			if
				link.add_todo(id, {
					path = filepath,
					line = task.line_num,
					content = task.content,
					tag = task.tag or "TODO",
					status = task.status,
					created_at = os.time(),
				})
			then
				report.created = report.created + 1
			end
		end
	end

	-- 处理删除
	for id, obj in pairs(existing) do
		obj.active = false
		obj.deleted_at = os.time()
		obj.deletion_reason = "标记已移除"
		store.set_key("todo.links.todo." .. id, obj)
		report.deleted = report.deleted + 1
	end

	report.success = report.created + report.updated + report.deleted > 0
	return report
end

---------------------------------------------------------------------
-- 核心：代码文件全量同步
---------------------------------------------------------------------
function M.sync_code_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false }
	end

	local lines = vim.fn.readfile(filepath)
	local keywords = config.get("code_keywords") or { "@todo" }
	local report = { created = 0, updated = 0, deleted = 0 }
	local current = {}

	-- 扫描当前文件
	for ln, line in ipairs(lines) do
		local tag, id = format.extract_from_code_line(line)
		if id then
			for _, kw in ipairs(keywords) do
				if line:match(kw) then
					current[id] = {
						id = id,
						path = filepath,
						line = ln,
						content = format.clean_content(
							line:gsub("%{%#[%x]+%}", ""):gsub(":ref:[%x]+", ""):gsub(kw, ""),
							tag or "CODE"
						),
						tag = tag or "CODE",
					}
					break
				end
			end
		end
	end

	-- 获取现有链接
	local existing = {}
	for _, obj in ipairs(index.find_code_links_by_file(filepath)) do
		existing[obj.id] = obj
	end

	-- 新增/更新
	for id, data in pairs(current) do
		if existing[id] then
			local old = existing[id]
			local dirty = false
			if old.line ~= data.line then
				old.line = data.line
				dirty = true
			end
			if old.content ~= data.content then
				old.content = data.content
				old.content_hash = locator.calculate_content_hash(data.content)
				dirty = true
			end
			if dirty then
				old.updated_at = os.time()
				store.set_key("todo.links.code." .. id, old)
				report.updated = report.updated + 1
			end
			existing[id] = nil
		else
			if link.add_code(id, data) then
				report.created = report.created + 1
			end
		end
	end

	-- 删除
	for id, obj in pairs(existing) do
		obj.active = false
		obj.deleted_at = os.time()
		obj.deletion_reason = "标记已移除"
		store.set_key("todo.links.code." .. id, obj)
		report.deleted = report.deleted + 1
	end

	report.success = report.created + report.updated + report.deleted > 0
	return report
end

---------------------------------------------------------------------
-- 位置修复
---------------------------------------------------------------------
function M.locate_file_links(filepath)
	return locator.locate_file_tasks and locator.locate_file_tasks(filepath) or { located = 0, total = 0 }
end

---------------------------------------------------------------------
-- 自动命令设置
---------------------------------------------------------------------
function M.setup_autofix()
	local group = vim.api.nvim_create_augroup("Todo2AutoFix", { clear = true })

	if config.get("sync.on_save") then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = { "*.todo", "*.md", "*.lua", "*.rs", "*.py", "*.js", "*.ts", "*.go", "*.java", "*.cpp" },
			callback = function(args)
				vim.schedule(function()
					local is_todo = args.file:match("%.todo%.md$")
						or args.file:match("%.todo$")
						or args.file:match("%.md$")
					local fn = is_todo and M.sync_todo_links or M.sync_code_links
					local report = fn(args.file)
					if config.get("sync.show_progress") and report.success then
						vim.notify(
							string.format(
								"%s同步: +%d ~%d -%d",
								is_todo and "TODO" or "代码",
								report.created,
								report.updated,
								report.deleted
							),
							vim.log.levels.INFO
						)
					end
				end)
			end,
		})
	end

	if config.get("autofix.enabled") then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = config.get("autofix.file_types") or { "*.todo", "*.md", "*.lua", "*.rs", "*.py", "*.js", "*.ts" },
			callback = function(args)
				vim.schedule(function()
					local result = M.locate_file_links(args.file)
					if result.located > 0 then
						vim.notify(
							string.format("修复 %d/%d 个行号", result.located, result.total),
							vim.log.levels.INFO
						)
					end
				end)
			end,
		})
	end
end

return M
