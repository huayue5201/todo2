-- lua/todo2/store/verification.lua
--- @module todo2.store.verification
--- 行号验证状态管理

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	AUTO_VERIFY_INTERVAL = 86400, -- 自动验证间隔（秒），默认24小时
	VERIFY_ON_FILE_SAVE = true, -- 文件保存时验证
	BATCH_SIZE = 50, -- 批量验证每次处理的链接数
}

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local last_verification_time = 0
local verification_queue = {}

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------
local function verify_single_link(link_obj, force_reverify)
	if not link_obj then
		return nil
	end

	-- 如果已经验证且不强制重新验证，直接返回
	if link_obj.line_verified and not force_reverify then
		return link_obj
	end

	-- 使用合并后的定位器验证链接
	local verified_link = locator.locate_task(link_obj)

	-- 更新验证状态
	local verified_line = verified_link.line or 0
	local original_line = link_obj.line or 0

	if verified_line == original_line and verified_link.path == link_obj.path then
		verified_link.line_verified = true
		verified_link.last_verified_at = os.time()
	else
		verified_link.line_verified = false
		verified_link.verification_failed_at = os.time()
		verified_link.verification_note = "行号已改变"
	end

	return verified_link
end

---------------------------------------------------------------------
-- 公共API
---------------------------------------------------------------------
--- 验证单个链接
--- @param id string 链接ID
--- @param link_type string|nil "todo", "code" 或 nil（两者都验证）
--- @param force boolean 是否强制重新验证
--- @return table 验证结果
function M.verify_link(id, link_type, force)
	local results = {}

	if not link_type or link_type == "todo" then
		local todo_link = link.get_todo(id)
		if todo_link then
			local verified = verify_single_link(todo_link, force)
			if verified then
				store.set_key("todo.links.todo." .. id, verified)
				results.todo = verified

				-- 记录验证日志
				M._log_verification(id, "todo", verified.line_verified)
			end
		end
	end

	if not link_type or link_type == "code" then
		local code_link = link.get_code(id)
		if code_link then
			local verified = verify_single_link(code_link, force)
			if verified then
				store.set_key("todo.links.code." .. id, verified)
				results.code = verified

				-- 记录验证日志
				M._log_verification(id, "code", verified.line_verified)
			end
		end
	end

	return results
end

--- 批量验证所有链接
--- @param opts table|nil 选项
--- @return table 验证报告
function M.verify_all(opts)
	opts = opts or {}
	local force = opts.force or false
	local batch_size = opts.batch_size or CONFIG.BATCH_SIZE
	local show_progress = opts.show_progress ~= false

	local report = {
		total_todo = 0,
		total_code = 0,
		verified_todo = 0,
		verified_code = 0,
		failed_todo = 0,
		failed_code = 0,
		unverified_todo = 0,
		unverified_code = 0,
	}

	-- 获取所有链接
	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	-- 验证TODO链接
	local todo_ids = {}
	for id, _ in pairs(all_todo) do
		table.insert(todo_ids, id)
	end

	if show_progress then
		vim.notify(string.format("开始验证 %d 个TODO链接...", #todo_ids), vim.log.levels.INFO)
	end

	for i, id in ipairs(todo_ids) do
		report.total_todo = report.total_todo + 1

		local result = M.verify_link(id, "todo", force)
		if result.todo then
			if result.todo.line_verified then
				report.verified_todo = report.verified_todo + 1
			else
				report.failed_todo = report.failed_todo + 1
			end
		else
			report.unverified_todo = report.unverified_todo + 1
		end

		-- 分批处理，避免阻塞
		if i % batch_size == 0 and show_progress then
			vim.schedule(function()
				vim.notify(string.format("已验证 %d/%d 个TODO链接", i, #todo_ids), vim.log.levels.INFO)
			end)
		end
	end

	-- 验证代码链接
	local code_ids = {}
	for id, _ in pairs(all_code) do
		table.insert(code_ids, id)
	end

	if show_progress then
		vim.notify(string.format("开始验证 %d 个代码链接...", #code_ids), vim.log.levels.INFO)
	end

	for i, id in ipairs(code_ids) do
		report.total_code = report.total_code + 1

		local result = M.verify_link(id, "code", force)
		if result.code then
			if result.code.line_verified then
				report.verified_code = report.verified_code + 1
			else
				report.failed_code = report.failed_code + 1
			end
		else
			report.unverified_code = report.unverified_code + 1
		end

		-- 分批处理
		if i % batch_size == 0 and show_progress then
			vim.schedule(function()
				vim.notify(string.format("已验证 %d/%d 个代码链接", i, #code_ids), vim.log.levels.INFO)
			end)
		end
	end

	-- 更新最后验证时间
	last_verification_time = os.time()
	M._update_verification_stats(report)

	report.summary = string.format(
		"验证完成: %d/%d TODO链接已验证, %d/%d 代码链接已验证",
		report.verified_todo,
		report.total_todo,
		report.verified_code,
		report.total_code
	)

	return report
end

--- 获取未验证的链接
--- @param days number|nil 多少天内未验证，nil表示所有
--- @return table 未验证链接列表
function M.get_unverified_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = {
		todo = {},
		code = {},
	}

	-- 检查TODO链接
	local all_todo = link.get_all_todo()
	for id, todo_link in pairs(all_todo) do
		local should_include = false

		if not todo_link.line_verified then
			should_include = true
		elseif cutoff_time > 0 then
			if not todo_link.last_verified_at or todo_link.last_verified_at < cutoff_time then
				should_include = true
			end
		end

		if should_include then
			result.todo[id] = todo_link
		end
	end

	-- 检查代码链接
	local all_code = link.get_all_code()
	for id, code_link in pairs(all_code) do
		local should_include = false

		if not code_link.line_verified then
			should_include = true
		elseif cutoff_time > 0 then
			if not code_link.last_verified_at or code_link.last_verified_at < cutoff_time then
				should_include = true
			end
		end

		if should_include then
			result.code[id] = code_link
		end
	end

	return result
end

--- 设置自动验证定时器
--- @param interval number|nil 验证间隔（秒），nil使用默认值
function M.setup_auto_verification(interval)
	local verify_interval = interval or CONFIG.AUTO_VERIFY_INTERVAL

	-- 创建自动命令组
	local group = vim.api.nvim_create_augroup("Todo2AutoVerification", { clear = true })

	-- 定时验证
	local timer = vim.loop.new_timer()
	timer:start(verify_interval * 1000, verify_interval * 1000, function()
		vim.schedule(function()
			local unverified = M.get_unverified_links(7) -- 7天未验证的

			local todo_count = 0
			for _ in pairs(unverified.todo) do
				todo_count = todo_count + 1
			end

			local code_count = 0
			for _ in pairs(unverified.code) do
				code_count = code_count + 1
			end

			if todo_count + code_count > 0 then
				vim.notify(
					string.format("发现 %d 个未验证的链接，正在自动验证...", todo_count + code_count),
					vim.log.levels.INFO
				)

				M.verify_all({ show_progress = false })
			end
		end)
	end)

	-- 文件保存时验证相关链接
	if CONFIG.VERIFY_ON_FILE_SAVE then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = "*",
			callback = function(args)
				vim.schedule(function()
					M.verify_file_links(args.file)
				end)
			end,
		})
	end

	-- 保存定时器引用以便后续管理
	M._timer = timer
end

--- 验证文件中的所有链接
--- @param filepath string 文件路径
--- @return table 验证结果
function M.verify_file_links(filepath)
	local index = require("todo2.store.index")
	local result = {
		total = 0,
		verified = 0,
		failed = 0,
	}

	-- 验证TODO链接
	local todo_links = index.find_todo_links_by_file(filepath)
	for _, todo_link in ipairs(todo_links) do
		result.total = result.total + 1

		local verified = verify_single_link(todo_link, false)
		if verified and verified.line_verified then
			result.verified = result.verified + 1
			store.set_key("todo.links.todo." .. todo_link.id, verified)
		else
			result.failed = result.failed + 1
		end
	end

	-- 验证代码链接
	local code_links = index.find_code_links_by_file(filepath)
	for _, code_link in ipairs(code_links) do
		result.total = result.total + 1

		local verified = verify_single_link(code_link, false)
		if verified and verified.line_verified then
			result.verified = result.verified + 1
			store.set_key("todo.links.code." .. code_link.id, verified)
		else
			result.failed = result.failed + 1
		end
	end

	return result
end

--- 获取验证统计信息
--- @return table 统计信息
function M.get_stats()
	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local stats = {
		total_links = 0,
		verified_links = 0,
		unverified_links = 0,
		verification_rate = 0,
		last_verification_time = last_verification_time,
	}

	-- 统计TODO链接
	for _, todo_link in pairs(all_todo) do
		stats.total_links = stats.total_links + 1
		if todo_link.line_verified then
			stats.verified_links = stats.verified_links + 1
		else
			stats.unverified_links = stats.unverified_links + 1
		end
	end

	-- 统计代码链接
	for _, code_link in pairs(all_code) do
		stats.total_links = stats.total_links + 1
		if code_link.line_verified then
			stats.verified_links = stats.verified_links + 1
		else
			stats.unverified_links = stats.unverified_links + 1
		end
	end

	-- 计算验证率
	if stats.total_links > 0 then
		stats.verification_rate = math.floor((stats.verified_links / stats.total_links) * 100)
	end

	return stats
end

---------------------------------------------------------------------
-- 内部函数
---------------------------------------------------------------------
function M._log_verification(id, link_type, success)
	local log_key = "todo.log.verification"
	local log = store.get_key(log_key) or {}

	table.insert(log, {
		id = id,
		type = link_type,
		success = success,
		timestamp = os.time(),
	})

	-- 只保留最近200条记录
	if #log > 200 then
		table.remove(log, 1)
	end

	store.set_key(log_key, log)
end

function M._update_verification_stats(report)
	local stats_key = "todo.stats.verification"
	local stats = store.get_key(stats_key) or {}

	stats.last_run = os.time()
	stats.total_runs = (stats.total_runs or 0) + 1
	stats.total_todo_verified = (stats.total_todo_verified or 0) + report.verified_todo
	stats.total_code_verified = (stats.total_code_verified or 0) + report.verified_code
	stats.total_failures = (stats.total_failures or 0) + report.failed_todo + report.failed_code

	store.set_key(stats_key, stats)
end

return M
