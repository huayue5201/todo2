-- lua/todo2/store/autofix.lua (终极修复版)
-- 自动修复模块 - 只修复物理位置，不覆盖状态

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

-- 定时清理
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

	-- 检查文件大小
	if not check_file_size(filepath) then
		return false
	end

	-- 1. TODO 文件永远处理
	if filepath:match("%.todo%.md$") or filepath:match("%.todo$") then
		return true
	end

	-- 2. 检查文件是否包含标记（快速检查前50行）
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
	-- 清理旧的计时器
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

		-- 执行处理
		local result = processor_fn(filepath)

		-- 调用所有回调
		for _, cb in ipairs(callbacks) do
			if cb then
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
		local result = processor_fn(filepath)
		if callback then
			callback(result)
		end
	else
		-- 节流中，使用防抖
		debounced_process(filepath, processor_fn, callback)
	end
end

---------------------------------------------------------------------
-- ⭐ 核心：TODO文件全量同步（修复版 - 不覆盖状态）
---------------------------------------------------------------------
function M.sync_todo_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false }
	end

	if not (filepath:match("%.todo%.md$") or filepath:match("%.todo$")) then
		return { success = false, skipped = true }
	end

	local tasks, _, id_to_task = parser.parse_file(filepath, true)

	local report = {
		created = 0,
		updated = 0,
		deleted = 0,
		ids = {},
	}

	-- 获取现有链接
	local existing = {}
	for _, obj in ipairs(index.find_todo_links_by_file(filepath)) do
		existing[obj.id] = obj
	end

	-- 处理新增和更新 - ⭐ 修复版：只更新物理位置，保留状态
	for id, task in pairs(id_to_task or {}) do
		table.insert(report.ids, id)

		if existing[id] then
			local old = existing[id]
			local dirty = false
			local changes = {}

			-- ⭐ 只更新物理位置相关字段
			if old.content ~= task.content then
				old.content = task.content
				old.content_hash = locator.calculate_content_hash(task.content)
				dirty = true
				table.insert(changes, "content")
			end

			if old.line ~= task.line_num then
				old.line = task.line_num
				dirty = true
				table.insert(changes, "line")
			end

			if old.tag ~= (task.tag or "TODO") then
				old.tag = task.tag or "TODO"
				dirty = true
				table.insert(changes, "tag")
			end

			-- ⭐ 关键修复：不同步 status！保留存储中的状态
			-- 状态只能由用户通过 core/status.lua 修改

			if dirty then
				old.updated_at = os.time()
				store.set_key("todo.links.todo." .. id, old)
				report.updated = report.updated + 1

				-- 调试信息（可选）
				if #changes > 0 then
					vim.notify(
						string.format("TODO链接 %s 已更新: %s", id:sub(1, 6), table.concat(changes, ", ")),
						vim.log.levels.DEBUG
					)
				end
			end
			existing[id] = nil
		else
			-- ⭐ 新增链接：使用文件中的初始状态
			if
				link.add_todo(id, {
					path = filepath,
					line = task.line_num,
					content = task.content,
					tag = task.tag or "TODO",
					status = task.status, -- 新增时使用文件中的状态
					created_at = os.time(),
				})
			then
				report.created = report.created + 1
			end
		end
	end

	-- 处理删除（软删除）
	for id, obj in pairs(existing) do
		table.insert(report.ids, id)
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
-- ⭐ 核心：代码文件全量同步（修复版 - 不覆盖状态）
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
		ids = {},
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

	-- ⭐ 新增/更新 - 修复版：保留所有存储字段
	for id, data in pairs(current) do
		table.insert(report.ids, id)

		if existing[id] then
			local old = existing[id]
			local dirty = false
			local changes = {}

			-- ⭐ 只更新物理位置相关字段，保留状态
			if old.line ~= data.line then
				old.line = data.line
				dirty = true
				table.insert(changes, "line")
			end
			if old.content ~= data.content then
				old.content = data.content
				old.content_hash = data.content_hash
				dirty = true
				table.insert(changes, "content")
			end
			if old.tag ~= data.tag then
				old.tag = data.tag
				dirty = true
				table.insert(changes, "tag")
			end

			-- ⭐ 关键修复：保留所有其他字段（status, previous_status, 时间戳等）
			-- old.status 保持不变
			-- old.previous_status 保持不变
			-- old.completed_at 保持不变
			-- old.archived_at 保持不变
			-- 等等...

			if dirty then
				old.updated_at = os.time()
				store.set_key("todo.links.code." .. id, old)
				report.updated = report.updated + 1

				-- 调试信息（可选）
				if #changes > 0 then
					vim.notify(
						string.format("代码链接 %s 已更新: %s", id:sub(1, 6), table.concat(changes, ", ")),
						vim.log.levels.DEBUG
					)
				end
			end
			existing[id] = nil
		else
			-- ⭐ 新增链接：使用默认状态 normal
			if link.add_code(id, data) then
				report.created = report.created + 1
			end
		end
	end

	-- 处理删除（跳过归档任务）
	for id, obj in pairs(existing) do
		table.insert(report.ids, id)

		-- 检查对应 TODO 是否为归档状态
		local todo_link = link.get_todo(id, { verify_line = false })

		if todo_link and types.is_archived_status(todo_link.status) then
			-- 归档任务：保留存储记录，不标记删除
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
-- 位置修复（带防抖）- 保持不变
---------------------------------------------------------------------
function M.locate_file_links(filepath, callback)
	if not filepath or filepath == "" then
		if callback then
			callback({ located = 0, total = 0 })
		end
		return { located = 0, total = 0 }
	end

	-- 先检查文件是否应该被处理
	if not M.should_process_file(filepath) then
		if callback then
			callback({ located = 0, total = 0, skipped = true })
		end
		return { located = 0, total = 0, skipped = true }
	end

	local function do_locate()
		local success, result = pcall(function()
			return locator.locate_file_tasks and locator.locate_file_tasks(filepath) or { located = 0, total = 0 }
		end)

		if not success then
			return { located = 0, total = 0, error = tostring(result) }
		end
		return result
	end

	if callback then
		-- 异步调用
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
-- 自动命令设置（修复版）
---------------------------------------------------------------------
function M.setup_autofix()
	local group = vim.api.nvim_create_augroup("Todo2AutoFix", { clear = true })

	-- 保存时同步（on_save）- 监听所有文件
	if config.get("autofix.on_save") then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = M.get_watch_patterns(),
			callback = function(args)
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
				-- 先快速检查是否应该处理
				if not M.should_process_file(args.file) then
					return
				end

				-- 使用节流处理（定位操作更重，用更保守的策略）
				throttled_process(args.file, function(file)
					return M.locate_file_links(file)
				end, function(result)
					if result and result.located and result.located > 0 then
						-- 可选：显示通知
						-- NOTE:ref:4108b8
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
