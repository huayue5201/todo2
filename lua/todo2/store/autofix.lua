-- lua/todo2/store/autofix.lua (终极修复版)
-- 自动修复模块 - 只修复物理位置，不覆盖状态（兼容统一软删除规则）
local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local index = require("todo2.store.index")
local config = require("todo2.config")
local parser = require("todo2.core.parser")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local verification = require("todo2.store.verification") -- 引入统一验证模块

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	DEBOUNCE_MS = 500, -- 防抖时间（毫秒）
	THROTTLE_MS = 5000, -- 节流时间（毫秒）
	MAX_FILE_SIZE_KB = 1024, -- 最大处理文件大小（KB）
}

---------------------------------------------------------------------
-- 防抖/节流控制
---------------------------------------------------------------------
local debounce_timers = {} -- 按文件路径存储的计时器
local last_run_time = {} -- 上次执行时间
local pending_files = {} -- 待处理的文件队列

-- 清理过期数据
local function cleanup_tracking()
	local now = vim.loop.now()
	for path, time in pairs(last_run_time) do
		if now - time > 60000 then -- 1分钟没活动就清理
			last_run_time[path] = nil
		end
	end

	for path, timer in pairs(debounce_timers) do
		if not timer:is_active() then
			debounce_timers[path] = nil
		end
	end
end

-- 定时清理（防止内存泄漏）
vim.loop.new_timer():start(30000, 30000, vim.schedule_wrap(cleanup_tracking))

---------------------------------------------------------------------
-- 文件过滤
---------------------------------------------------------------------

--- 检查文件大小是否在限制内
--- @param filepath string
--- @return boolean
local function check_file_size(filepath)
	local stat = vim.loop.fs_stat(filepath)
	if not stat then
		return false
	end
	local size_kb = stat.size / 1024
	return size_kb <= CONFIG.MAX_FILE_SIZE_KB
end

--- 检查文件是否应该被处理（基于实际内容，而非扩展名）
--- @param filepath string 文件路径
--- @return boolean 是否应该处理
function M.should_process_file(filepath)
	if not filepath or filepath == "" then
		return false
	end

	-- 检查文件大小（过大的文件跳过处理）
	if not check_file_size(filepath) then
		return false
	end

	-- 1. TODO 文件永远处理
	if filepath:match("%.todo%.md$") or filepath:match("%.todo$") then
		return true
	end

	-- 2. 检查文件是否包含标记（快速检查前50行，提升性能）
	local ok, lines = pcall(function()
		return vim.fn.readfile(filepath, "", 50) -- 只读前50行
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
-- 防抖/节流处理函数
---------------------------------------------------------------------
local function debounced_process(filepath, processor_fn, callback)
	-- 清理旧的计时器（防止重复执行）
	if debounce_timers[filepath] then
		debounce_timers[filepath]:stop()
		debounce_timers[filepath]:close()
		debounce_timers[filepath] = nil
	end

	-- 添加到待处理队列
	pending_files[filepath] = pending_files[filepath] or {}
	table.insert(pending_files[filepath], callback)

	-- 创建新的防抖计时器
	debounce_timers[filepath] = vim.defer_fn(function()
		local callbacks = pending_files[filepath] or {}
		pending_files[filepath] = nil

		-- 执行处理（包裹pcall防止崩溃）
		local success, result = pcall(processor_fn, filepath)
		if not success then
			vim.notify(string.format("自动修复处理失败: %s", tostring(result)), vim.log.levels.ERROR)
			result = { success = false, error = tostring(result) }
		end

		-- 调用所有回调
		for _, cb in ipairs(callbacks) do
			if type(cb) == "function" then
				pcall(cb, result)
			end
		end

		debounce_timers[filepath] = nil
	end, CONFIG.DEBOUNCE_MS)
end

local function throttled_process(filepath, processor_fn, callback)
	local now = vim.loop.now()
	local last = last_run_time[filepath] or 0

	if now - last >= CONFIG.THROTTLE_MS then
		-- 可以执行
		last_run_time[filepath] = now
		local success, result = pcall(processor_fn, filepath)
		if not success then
			vim.notify(string.format("节流处理失败: %s", tostring(result)), vim.log.levels.ERROR)
			result = { success = false, error = tostring(result) }
		end
		if type(callback) == "function" then
			callback(result)
		end
	else
		-- 节流中，使用防抖
		debounced_process(filepath, processor_fn, callback)
	end
end

---------------------------------------------------------------------
-- ⭐ 核心修复：智能更新链接（区分内容变更和位置变更）
---------------------------------------------------------------------
local function update_link_with_changes(old, updates, report, link_type)
	local content_changed = false
	local position_changed = false
	local changes = {}

	-- 安全检查：确保old对象有效
	if not old or type(old) ~= "table" then
		return false, {}, "无效对象"
	end

	-- 内容变化检查（应该触发时间戳）
	if updates.content and old.content ~= updates.content then
		old.content = updates.content
		old.content_hash = updates.content_hash or locator.calculate_content_hash(updates.content)
		content_changed = true
		table.insert(changes, "content")
	end

	if updates.tag and old.tag ~= updates.tag then
		old.tag = updates.tag
		content_changed = true
		table.insert(changes, "tag")
	end

	-- ⚠️ 核心修复：不覆盖状态（status），仅同步位置
	-- 注释掉状态更新逻辑，确保状态不被覆盖
	-- if updates.status and old.status ~= updates.status then
	-- 	old.status = updates.status
	-- 	content_changed = true
	-- 	table.insert(changes, "status")
	-- end

	-- 位置变化检查（不应该触发时间戳）
	if updates.line and old.line ~= updates.line then
		old.line = updates.line
		position_changed = true
		table.insert(changes, "line")
	end

	if updates.path and old.path ~= updates.path then
		-- 如果路径变化，需要更新索引
		if old.path and updates.path then
			local index_ns = (link_type == "todo") and "todo.index.file_to_todo" or "todo.index.file_to_code"
			-- 安全调用索引更新
			pcall(index._remove_id_from_file_index, index_ns, old.path, old.id)
			pcall(index._add_id_to_file_index, index_ns, updates.path, old.id)
		end
		old.path = updates.path
		position_changed = true
		table.insert(changes, "path")
	end

	-- ⭐ 修复：只有内容变化才更新 updated_at
	if content_changed then
		old.updated_at = os.time()
		report.updated = report.updated + 1
	elseif position_changed then
		-- 位置变化：只更新位置，不更新时间戳
		report.updated = report.updated + 1
	end

	return (content_changed or position_changed), changes, (content_changed and "内容" or "位置")
end

---------------------------------------------------------------------
-- 核心：TODO文件全量同步（修复版 - 不覆盖状态 + 兼容软删除）
---------------------------------------------------------------------
function M.sync_todo_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false, error = "空文件路径" }
	end

	if not (filepath:match("%.todo%.md$") or filepath:match("%.todo$")) then
		return { success = false, skipped = true, reason = "非TODO文件" }
	end

	-- 安全解析文件
	local ok, tasks, _, id_to_task = pcall(parser.parse_file, filepath, true)
	if not ok then
		vim.notify(string.format("解析TODO文件失败: %s", tostring(tasks)), vim.log.levels.ERROR)
		return { success = false, error = "解析文件失败: " .. tostring(tasks) }
	end

	local report = {
		created = 0,
		updated = 0,
		deleted = 0,
		ids = {},
	}

	-- 获取现有链接（安全调用）
	local existing = {}
	local ok_existing, existing_links = pcall(index.find_todo_links_by_file, filepath)
	if ok_existing and existing_links then
		for _, obj in ipairs(existing_links) do
			existing[obj.id] = obj
		end
	end

	for id, task in pairs(id_to_task or {}) do
		table.insert(report.ids, id)

		if existing[id] then
			local old = existing[id]

			-- 使用辅助函数智能更新（不覆盖状态）
			local changed, changes, change_type = update_link_with_changes(old, {
				content = task.content,
				tag = task.tag or "TODO",
				-- 不传递status，确保状态不被覆盖
				line = task.line_num,
				path = filepath,
				content_hash = locator.calculate_content_hash(task.content),
			}, report, "todo")

			if changed then
				-- 安全保存更新
				pcall(store.set_key, "todo.links.todo." .. id, old)

				-- 调试信息
				if #changes > 0 then
					vim.notify(
						string.format(
							"TODO链接 %s %s变化: %s",
							id:sub(1, 6),
							change_type,
							table.concat(changes, ", ")
						),
						vim.log.levels.DEBUG
					)
				end
			end
			existing[id] = nil
		else
			-- 新增链接：使用文件中的初始状态
			local add_ok = pcall(link.add_todo, id, {
				path = filepath,
				line = task.line_num,
				content = task.content,
				tag = task.tag or "TODO",
				status = task.status,
				created_at = os.time(),
				active = true,
			})
			if add_ok then
				report.created = report.created + 1
			end
		end
	end

	-- 处理删除（兼容软删除）
	for id, obj in pairs(existing) do
		table.insert(report.ids, id)
		-- 安全标记删除
		pcall(verification.mark_link_deleted, id, "todo")
		report.deleted = report.deleted + 1
	end

	-- 刷新元数据
	pcall(verification.refresh_metadata_stats)

	report.success = report.created + report.updated + report.deleted > 0
	return report
end

---------------------------------------------------------------------
-- 核心：代码文件全量同步（修复版 - 不覆盖状态 + 兼容软删除）
---------------------------------------------------------------------
function M.sync_code_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false, error = "空文件路径" }
	end

	if not M.should_process_file(filepath) then
		return { success = false, skipped = true, reason = "文件无需处理" }
	end

	-- 安全读取文件
	local ok, lines = pcall(vim.fn.readfile, filepath)
	if not ok or not lines then
		return { success = false, error = "无法读取文件: " .. tostring(lines) }
	end

	local keywords = config.get_code_keywords() or { "@todo" }
	local report = {
		created = 0,
		updated = 0,
		deleted = 0,
		ids = {},
	}
	local current = {}

	-- 解析代码文件中的标记
	for ln, line in ipairs(lines) do
		local tag, id = format.extract_from_code_line(line)
		if id then
			for _, kw in ipairs(keywords) do
				if line:match(kw) then
					if not tag then
						tag = config.get_tag_name_by_keyword(kw) or "TODO"
					end

					-- ✅ 修复：正确拆分多行，清理内容
					local cleaned_content = line:gsub("%{%#" .. id .. "%}", "")
						:gsub(":ref:" .. id, "")
						:gsub(kw, "")
						:gsub("%s+$", "")
						:gsub("^%s+", "")

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
						active = true,
					}
					break
				end
			end
		end
	end

	if vim.tbl_isempty(current) then
		return { success = false, skipped = true, reason = "无待处理标记" }
	end

	-- 获取现有代码链接
	local existing = {}
	local ok_existing, existing_links = pcall(index.find_code_links_by_file, filepath)
	if ok_existing and existing_links then
		for _, obj in ipairs(existing_links) do
			existing[obj.id] = obj
		end
	end

	-- 新增/更新
	for id, data in pairs(current) do
		table.insert(report.ids, id)

		if existing[id] then
			local old = existing[id]

			-- 使用辅助函数智能更新（不覆盖状态）
			local changed, changes, change_type = update_link_with_changes(old, {
				content = data.content,
				tag = data.tag,
				line = data.line,
				path = data.path,
				content_hash = data.content_hash,
			}, report, "code")

			if changed then
				pcall(store.set_key, "todo.links.code." .. id, old)

				if #changes > 0 then
					vim.notify(
						string.format(
							"代码链接 %s %s变化: %s",
							id:sub(1, 6),
							change_type,
							table.concat(changes, ", ")
						),
						vim.log.levels.DEBUG
					)
				end
			end
			existing[id] = nil
		else
			local add_ok = pcall(link.add_code, id, data)
			if add_ok then
				report.created = report.created + 1
			end
		end
	end

	-- 处理删除（兼容软删除和归档状态）
	for id, obj in pairs(existing) do
		table.insert(report.ids, id)

		-- 检查是否是归档任务
		local todo_link_ok, todo_link = pcall(link.get_todo, id, { verify_line = false })
		local is_archived = false
		if todo_link_ok and todo_link then
			is_archived = types.is_archived_status(todo_link.status)
		end

		if is_archived then
			-- 归档任务：保留存储记录
		else
			-- 非归档任务：标记删除
			pcall(verification.mark_link_deleted, id, "code")
			report.deleted = report.deleted + 1
		end
	end

	-- 刷新元数据
	pcall(verification.refresh_metadata_stats)

	report.success = report.created + report.updated + report.deleted > 0
	return report
end

---------------------------------------------------------------------
-- 位置修复（带防抖）- 增强稳定性
---------------------------------------------------------------------
function M.locate_file_links(filepath, callback)
	if not filepath or filepath == "" then
		local result = { located = 0, total = 0, error = "空文件路径" }
		if type(callback) == "function" then
			callback(result)
		end
		return result
	end

	-- 先检查文件是否应该被处理
	if not M.should_process_file(filepath) then
		local result = { located = 0, total = 0, skipped = true, reason = "文件无需处理" }
		if type(callback) == "function" then
			callback(result)
		end
		return result
	end

	local function do_locate()
		local success, result = pcall(function()
			if type(locator.locate_file_tasks) == "function" then
				return locator.locate_file_tasks(filepath)
			else
				return { located = 0, total = 0, error = "locator.locate_file_tasks 未定义" }
			end
		end)

		if not success then
			return { located = 0, total = 0, error = tostring(result) }
		end
		return result
	end

	if type(callback) == "function" then
		-- 异步调用（避免阻塞主线程）
		vim.schedule(function()
			local result = do_locate()
			callback(result)
		end)
		return { located = 0, total = 0, processing = true }
	else
		-- 同步调用
		return do_locate()
	end
end

---------------------------------------------------------------------
-- 自动命令设置（修复版 - 增强稳定性）
---------------------------------------------------------------------
function M.setup_autofix()
	-- 先销毁旧的自动命令组，防止重复创建
	pcall(vim.api.nvim_del_augroup_by_name, "Todo2AutoFix")

	local group = vim.api.nvim_create_augroup("Todo2AutoFix", { clear = true })

	-- 保存时同步（on_save）- 监听所有文件
	if config.get("autofix.on_save") then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = M.get_watch_patterns(),
			callback = function(args)
				-- 快速跳过无效文件
				if not args.file or args.file == "" then
					return
				end

				-- 先快速检查是否应该处理
				if not M.should_process_file(args.file) then
					return
				end

				-- 判断是TODO文件还是代码文件
				local is_todo = args.file:match("%.todo%.md$") or args.file:match("%.todo$")
				local fn = is_todo and M.sync_todo_links or M.sync_code_links

				-- 使用防抖处理
				debounced_process(args.file, fn, function(report)
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
			pattern = M.get_watch_patterns(),
			callback = function(args)
				-- 快速跳过无效文件
				if not args.file or args.file == "" then
					return
				end

				-- 先快速检查是否应该处理
				if not M.should_process_file(args.file) then
					return
				end

				-- 使用节流处理（定位操作更重，用更保守的策略）
				throttled_process(args.file, function(file)
					return M.locate_file_links(file)
				end, function(result)
					if result and result.located and result.located > 0 then
						if config.get("autofix.show_progress") then
							vim.notify(
								string.format("修复 %d/%d 个行号", result.located, result.total or 0),
								vim.log.levels.INFO
							)
						end
					end
				end)
			end,
		})
	end
end

-- 导出配置（方便调试和调整）
M.set_config = function(new_config)
	if type(new_config) ~= "table" then
		vim.notify("配置必须是table类型", vim.log.levels.WARN)
		return
	end
	for k, v in pairs(new_config) do
		if CONFIG[k] ~= nil then
			CONFIG[k] = v
		end
	end
end

M.get_config = function()
	return vim.deepcopy(CONFIG)
end

return M
