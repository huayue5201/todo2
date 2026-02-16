-- lua/todo2/store/autofix.lua
-- 自动修复模块

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local index = require("todo2.store.index")
local config = require("todo2.config")
local parser = require("todo2.core.parser")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 判断是否应该处理该文件
---------------------------------------------------------------------

--- 检查文件是否应该被处理（基于实际内容，而非扩展名）
--- @param filepath string 文件路径
--- @return boolean 是否应该处理
function M.should_process_file(filepath)
	if not filepath or filepath == "" then
		return false
	end

	-- 1. TODO 文件永远处理
	if filepath:match("%.todo%.md$") or filepath:match("%.todo$") then
		return true
	end

	-- 2. 检查文件是否包含标记（快速检查前100行）
	local ok, lines = pcall(function()
		return vim.fn.readfile(filepath, "", 100) -- 只读前100行
	end)

	if not ok or not lines then
		return false
	end

	-- 查找是否有任何标记
	for _, line in ipairs(lines) do
		-- 检查 {#id} 格式
		if line:match("{%#%x+%}") then
			return true
		end
		-- 检查 :ref:id 格式
		if line:match(":ref:%x+") then
			return true
		end
		-- 检查带关键词的标记（从配置获取）
		local keywords = config.get_code_keywords()
		for _, kw in ipairs(keywords) do
			if line:match(kw) and (line:match("{%#%x+%}") or line:match(":ref:%x+")) then
				return true
			end
		end
	end

	return false
end

--- 获取所有应该监听的文件模式（用于 autocmd）
--- @return table 文件模式列表
function M.get_watch_patterns()
	-- 返回一个通配模式，匹配所有文件
	-- 因为我们会用 should_process_file 做实际检查
	return { "*" }
end

---------------------------------------------------------------------
-- 核心：TODO文件全量同步（增强版）
---------------------------------------------------------------------
function M.sync_todo_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false }
	end

	-- 如果不是 TODO 文件，跳过
	if not (filepath:match("%.todo%.md$") or filepath:match("%.todo$")) then
		return { success = false, skipped = true }
	end

	local _, _, id_to_task = parser.parse_file(filepath, true)
	local report = {
		created = 0,
		updated = 0,
		deleted = 0,
		ids = {}, -- ⭐ 记录所有受影响的ID
	}

	-- 获取现有链接
	local existing = {}
	for _, obj in ipairs(index.find_todo_links_by_file(filepath)) do
		existing[obj.id] = obj
	end

	-- 处理新增和更新
	for id, task in pairs(id_to_task or {}) do
		table.insert(report.ids, id) -- ⭐ 记录ID

		if existing[id] then
			local old = existing[id]
			local dirty = false

			-- 检查所有字段变化
			if old.line ~= task.line_num then
				old.line = task.line_num
				dirty = true
			end
			-- ⭐ 关键：检查 content 是否变化
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
		table.insert(report.ids, id) -- ⭐ 记录被删除的ID
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
-- 核心：代码文件全量同步（自动检测文件类型）
---------------------------------------------------------------------
function M.sync_code_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false }
	end

	-- 先检查文件是否应该被处理
	if not M.should_process_file(filepath) then
		return { success = false, skipped = true }
	end

	-- 读取文件内容
	local ok, lines = pcall(vim.fn.readfile, filepath)
	if not ok or not lines then
		return { success = false, error = "无法读取文件" }
	end

	-- 从 tags 自动生成 keywords
	local keywords = config.get_code_keywords() or { "@todo" }
	local report = {
		created = 0,
		updated = 0,
		deleted = 0,
		ids = {}, -- ⭐ 记录所有受影响的ID
	}
	local current = {}

	-- 扫描当前文件
	for ln, line in ipairs(lines) do
		-- 从代码行提取标签和ID
		local tag, id = format.extract_from_code_line(line)
		if id then
			for _, kw in ipairs(keywords) do
				if line:match(kw) then
					-- 如果没有提取到 tag，从关键词反查
					if not tag then
						tag = config.get_tag_name_by_keyword(kw) or "TODO"
					end

					-- 清理内容：移除ID标记、关键词和ref标记
					local cleaned_content = line
						:gsub("%{%#" .. id .. "%}", "") -- 移除 {#id}
						:gsub(":ref:" .. id, "") -- 移除 :ref:id
						:gsub(kw, "") -- 移除关键词
						:gsub("%s+$", "") -- 移除尾部空格
						:gsub("^%s+", "") -- 移除头部空格

					-- 如果清理后为空，使用默认内容
					if cleaned_content == "" then
						cleaned_content = "任务标记"
					end

					current[id] = {
						id = id,
						path = filepath,
						line = ln,
						content = cleaned_content,
						tag = tag or "CODE",
						content_hash = locator.calculate_content_hash(cleaned_content),
					}
					break
				end
			end
		end
	end

	-- 如果没有找到任何标记，跳过
	if vim.tbl_isempty(current) then
		return { success = false, skipped = true }
	end

	-- 获取现有链接
	local existing = {}
	for _, obj in ipairs(index.find_code_links_by_file(filepath)) do
		existing[obj.id] = obj
	end

	-- 新增/更新
	for id, data in pairs(current) do
		table.insert(report.ids, id) -- ⭐ 记录ID

		if existing[id] then
			local old = existing[id]
			local dirty = false

			if old.line ~= data.line then
				old.line = data.line
				dirty = true
			end
			if old.content ~= data.content then
				old.content = data.content
				old.content_hash = data.content_hash
				dirty = true
			end
			if old.tag ~= data.tag then
				old.tag = data.tag
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

	-- 处理删除（跳过归档任务）
	for id, obj in pairs(existing) do
		table.insert(report.ids, id) -- ⭐ 记录被删除的ID

		-- 检查对应 TODO 是否为归档状态
		local todo_link = link.get_todo(id, { verify_line = false })

		if todo_link and types.is_archived_status(todo_link.status) then
			-- 归档任务：保留存储记录，不标记删除
			-- 不修改 obj，保留原样
		else
			-- 非归档任务：正常标记为删除
			obj.active = false
			obj.deleted_at = os.time()
			obj.deletion_reason = "标记已移除"
			store.set_key("todo.links.code." .. id, obj)
			report.deleted = report.deleted + 1
		end
	end

	report.success = report.created + report.updated + report.deleted > 0
	return report
end

---------------------------------------------------------------------
-- 位置修复
---------------------------------------------------------------------
function M.locate_file_links(filepath)
	if not filepath or filepath == "" then
		return { located = 0, total = 0 }
	end

	-- 先检查文件是否应该被处理
	if not M.should_process_file(filepath) then
		return { located = 0, total = 0, skipped = true }
	end

	local success, result = pcall(function()
		return locator.locate_file_tasks and locator.locate_file_tasks(filepath) or { located = 0, total = 0 }
	end)

	if not success then
		return { located = 0, total = 0, error = tostring(result) }
	end

	return result
end

---------------------------------------------------------------------
-- 自动命令设置
---------------------------------------------------------------------
function M.setup_autofix()
	local group = vim.api.nvim_create_augroup("Todo2AutoFix", { clear = true })

	-- 保存时同步（on_save）- 监听所有文件
	if config.get("autofix.on_save") then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = M.get_watch_patterns(), -- 返回 { "*" }
			callback = function(args)
				vim.schedule(function()
					-- 先检查文件是否应该被处理
					if not M.should_process_file(args.file) then
						return
					end

					-- 判断是TODO文件还是代码文件
					local is_todo = args.file:match("%.todo%.md$") or args.file:match("%.todo$")

					local fn = is_todo and M.sync_todo_links or M.sync_code_links
					local report = fn(args.file)

					if config.get("autofix.show_progress") and report and report.success then
						local msg = string.format(
							"%s同步: +%d ~%d -%d",
							is_todo and "TODO" or "代码",
							report.created or 0,
							report.updated or 0,
							report.deleted or 0
						)
						vim.notify(msg, vim.log.levels.INFO)
					end
				end)
			end,
		})
	end

	-- 自动修复位置（enabled）- 监听所有文件
	if config.get("autofix.enabled") then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = M.get_watch_patterns(), -- 返回 { "*" }
			callback = function(args)
				vim.schedule(function()
					-- 先检查文件是否应该被处理
					if not M.should_process_file(args.file) then
						return
					end

					local result = M.locate_file_links(args.file)
					if result and result.located and result.located > 0 then
						vim.notify(
							string.format("修复 %d/%d 个行号", result.located, result.total or 0),
							vim.log.levels.INFO
						)
					end
				end)
			end,
		})
	end
end

return M
