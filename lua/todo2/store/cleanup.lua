-- lua/todo2/store/cleanup.lua (增强版 - 添加悬挂数据清理)
-- 数据清理与维护

local M = {}

local link = require("todo2.store.link")
local index = require("todo2.store.index")
local lifecycle = require("todo2.store.link_lifecycle")
local id_utils = require("todo2.utils.id")

----------------------------------------------------------------------
-- 通用清理函数（保持不变）
----------------------------------------------------------------------
local function cleanup_expired_links(link_type, days)
	local now = os.time()
	local threshold = now - days * 86400
	local cleaned = 0
	local get_all_fun = link_type == "todo" and link.get_all_todo or link.get_all_code
	local delete_fun = link_type == "todo" and link.delete_todo or link.delete_code

	for id, link_obj in pairs(get_all_fun()) do
		if (link_obj.created_at or 0) < threshold then
			delete_fun(id)
			cleaned = cleaned + 1
		end
	end
	return cleaned
end

local function validate_links(link_type, all_todo, all_code, summary, verbose)
	local get_all_fun = link_type == "todo" and link.get_all_todo or link.get_all_code
	local opposite_links = link_type == "todo" and all_code or all_todo

	for id, link_obj in pairs(get_all_fun()) do
		summary["total_" .. link_type] = summary["total_" .. link_type] + 1

		local norm_path = index._normalize_path(link_obj.path)
		if vim.fn.filereadable(norm_path) == 0 then
			summary.missing_files = summary.missing_files + 1
			summary.broken_links = summary.broken_links + 1
			if verbose then
				vim.notify(
					"缺失" .. (link_type == "todo" and "TODO" or "代码") .. "文件: " .. (link_obj.path or "<?>"),
					vim.log.levels.DEBUG
				)
			end
		end

		if not opposite_links[id] then
			summary["orphan_" .. link_type] = summary["orphan_" .. link_type] + 1
			summary.broken_links = summary.broken_links + 1
			if verbose then
				vim.notify(
					"孤立" .. (link_type == "todo" and "TODO" or "代码") .. "标记: " .. id,
					vim.log.levels.DEBUG
				)
			end
		end
	end
end

local function relocate_link(link_obj, verbose)
	local norm_path = index._normalize_path(link_obj.path)
	if vim.fn.filereadable(norm_path) == 0 then
		if verbose then
			vim.notify(string.format("文件不存在，无法重定位: %s", link_obj.path), vim.log.levels.WARN)
		end
		return link_obj
	else
		local locator = require("todo2.store.locator")
		local relocated = locator.locate_task(link_obj)
		if relocated.path ~= link_obj.path or relocated.line ~= link_obj.line then
			if verbose then
				vim.notify(
					string.format("重新定位链接: %s:%d", relocated.path, relocated.line),
					vim.log.levels.INFO
				)
			end
			return relocated
		end
		return link_obj
	end
end

----------------------------------------------------------------------
-- ⭐ 修改：检查链接是否存在于文件中（使用 id_utils）
----------------------------------------------------------------------
--- 检查链接是否存在于文件中
--- @param link_obj table 链接对象
--- @return boolean 是否存在
local function link_exists_in_file(link_obj)
	if not link_obj or not link_obj.path or not link_obj.id then
		return false
	end

	-- 文件不存在，肯定不存在
	if vim.fn.filereadable(link_obj.path) ~= 1 then
		return false
	end

	local lines = vim.fn.readfile(link_obj.path)
	if not lines or #lines == 0 then
		return false
	end

	-- 检查行号是否有效且行内容包含ID
	if link_obj.line and link_obj.line >= 1 and link_obj.line <= #lines then
		local line = lines[link_obj.line]
		if line then
			-- ⭐ 使用 id_utils 检查两种标记
			if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == link_obj.id then
				return true
			end
			if id_utils.contains_code_mark(line) and id_utils.extract_id_from_code_mark(line) == link_obj.id then
				return true
			end
		end
	end

	-- 如果指定行没有找到，全局搜索文件（文件可能被编辑，行号变了）
	for _, line in ipairs(lines) do
		if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == link_obj.id then
			return true
		end
		if id_utils.contains_code_mark(line) and id_utils.extract_id_from_code_mark(line) == link_obj.id then
			return true
		end
	end

	return false
end

----------------------------------------------------------------------
-- ⭐ 修改：判断是否为真正的悬挂数据（两端都不在文件中）
----------------------------------------------------------------------
--- 判断链接对是否为悬挂数据
--- @param id string 链接ID
--- @param todo_obj table|nil TODO端对象
--- @param code_obj table|nil 代码端对象
--- @return boolean 是否为悬挂数据
--- @return string|nil 原因
local function is_dangling_pair(id, todo_obj, code_obj)
	-- 情况1：两端都不存在（都已经从存储中删除）- 不需要处理
	if not todo_obj and not code_obj then
		return false, "两端都不存在"
	end

	-- 使用生命周期模块获取状态类别（纯数据判定）
	local todo_class = todo_obj and lifecycle.get_state_class(todo_obj)
	local code_class = code_obj and lifecycle.get_state_class(code_obj)

	-- 情况2：任一端已归档，不清理（归档是故意的）
	if todo_class == lifecycle.STATE_CLASS.ARCHIVED or code_class == lifecycle.STATE_CLASS.ARCHIVED then
		return false, "已归档"
	end

	-- 情况3：只有一端存在且已软删除，另一端不存在
	-- 场景：只有TODO端存在且已软删除，代码端不存在
	if todo_class == lifecycle.STATE_CLASS.DELETED and not code_obj then
		-- 检查TODO端是否还在文件中
		if not link_exists_in_file(todo_obj) then
			return true, "孤立软删除TODO端（文件中不存在）"
		else
			return false, "孤立软删除TODO端（文件中还存在）"
		end
	end

	-- 场景：只有代码端存在且已软删除，TODO端不存在
	if code_class == lifecycle.STATE_CLASS.DELETED and not todo_obj then
		-- 检查代码端是否还在文件中
		if not link_exists_in_file(code_obj) then
			return true, "孤立软删除代码端（文件中不存在）"
		else
			return false, "孤立软删除代码端（文件中还存在）"
		end
	end

	-- 情况4：两端都存在
	if todo_obj and code_obj then
		-- 检查两端是否在文件中存在
		local todo_exists = link_exists_in_file(todo_obj)
		local code_exists = link_exists_in_file(code_obj)

		-- 如果两端都不在文件中，清理
		if not todo_exists and not code_exists then
			return true, "两端在文件中都不存在"
		end

		-- 如果一端不在文件中，另一端已软删除，也可以清理
		if not todo_exists and code_class == lifecycle.STATE_CLASS.DELETED then
			return true, "TODO端不在文件中，代码端已软删除"
		end
		if not code_exists and todo_class == lifecycle.STATE_CLASS.DELETED then
			return true, "代码端不在文件中，TODO端已软删除"
		end

		-- 其他情况保留
		if not todo_exists then
			return false, "TODO端不在文件中，但代码端还在"
		end
		if not code_exists then
			return false, "代码端不在文件中，但TODO端还在"
		end
	end

	-- 情况5：只有一端存在（没有软删除），检查文件存在性
	if todo_obj and not code_obj then
		if not link_exists_in_file(todo_obj) then
			return true, "TODO端在文件中不存在，代码端也不存在"
		end
		return false, "TODO端还在文件中"
	end

	if code_obj and not todo_obj then
		if not link_exists_in_file(code_obj) then
			return true, "代码端在文件中不存在，TODO端也不存在"
		end
		return false, "代码端还在文件中"
	end

	return false, "至少一端存在"
end

----------------------------------------------------------------------
-- ⭐ 修复：清理悬挂数据（两端都不存在）
----------------------------------------------------------------------
--- 清理悬挂数据
--- @param opts table|nil 选项
---   - dry_run: boolean 是否试运行（只报告不删除）
---   - verbose: boolean 是否输出详细信息
--- @return table 清理报告
function M.cleanup_dangling_links(opts)
	opts = opts or {}
	local dry_run = opts.dry_run or false
	local verbose = opts.verbose or false

	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()
	local all_ids = {}

	-- 收集所有ID
	for id, _ in pairs(all_todo) do
		all_ids[id] = true
	end
	for id, _ in pairs(all_code) do
		all_ids[id] = true
	end

	local report = {
		dangling_pairs = 0, -- 真正需要清理的悬挂对
		checked = 0,
		skipped = {
			archived = 0, -- 归档状态跳过
			todo_only = 0, -- 只有TODO端，且TODO端还在文件中
			code_only = 0, -- 只有代码端，且代码端还在文件中
			both_exist = 0, -- 两端都存在，且至少一端在文件中
		},
		details = {},
	}

	-- 检查每个ID
	for id, _ in pairs(all_ids) do
		local todo_obj = all_todo[id]
		local code_obj = all_code[id]
		report.checked = report.checked + 1

		-- 判断是否为悬挂数据
		local is_dangling, reason = is_dangling_pair(id, todo_obj, code_obj)

		if is_dangling then
			-- 真正的悬挂数据，清理两端
			if verbose then
				vim.notify(string.format("清理悬挂链接 %s: %s", id, reason), vim.log.levels.WARN)
			end

			table.insert(report.details, {
				id = id,
				action = "delete",
				reason = reason,
				has_todo = todo_obj ~= nil,
				has_code = code_obj ~= nil,
			})

			if not dry_run then
				if todo_obj then
					-- ⭐ 直接硬删除，不经过软删除
					link.delete_todo(id)
				end
				if code_obj then
					link.delete_code(id)
				end

				-- ⭐ 清理文件索引中的记录
				if todo_obj and todo_obj.path then
					index._remove_id_from_file_index("todo.index.file_to_todo", todo_obj.path, id)
				end
				if code_obj and code_obj.path then
					index._remove_id_from_file_index("todo.index.file_to_code", code_obj.path, id)
				end
			end
			report.dangling_pairs = report.dangling_pairs + 1
		else
			-- 统计跳过原因
			local skip_reason = reason or "未知"
			if skip_reason:find("归档") then
				report.skipped.archived = report.skipped.archived + 1
			elseif todo_obj and not code_obj then
				report.skipped.todo_only = report.skipped.todo_only + 1
			elseif code_obj and not todo_obj then
				report.skipped.code_only = report.skipped.code_only + 1
			elseif todo_obj and code_obj then
				report.skipped.both_exist = report.skipped.both_exist + 1
			end

			table.insert(report.details, {
				id = id,
				action = "skip",
				reason = skip_reason,
				has_todo = todo_obj ~= nil,
				has_code = code_obj ~= nil,
			})
		end
	end

	-- ⭐ 更新元数据
	if not dry_run and report.dangling_pairs > 0 then
		local verification = require("todo2.store.verification")
		pcall(verification.refresh_metadata_stats)
	end

	report.summary = string.format(
		"检查 %d 个链接对，清理 %d 个悬挂对（跳过: 归档 %d, 仅TODO %d, 仅代码 %d, 双端存在 %d）",
		report.checked,
		report.dangling_pairs,
		report.skipped.archived,
		report.skipped.todo_only,
		report.skipped.code_only,
		report.skipped.both_exist
	)

	return report
end

----------------------------------------------------------------------
-- ⭐ 新增：在验证结果中包含悬挂统计
----------------------------------------------------------------------
--- 验证所有链接（增强版）
--- @param opts table|nil
--- @return table
function M.validate_all(opts)
	opts = opts or {}
	local verbose = opts.verbose or false

	local all_code = link.get_all_code()
	local all_todo = link.get_all_todo()

	local summary = {
		total_code = 0,
		total_todo = 0,
		orphan_code = 0,
		orphan_todo = 0,
		missing_files = 0,
		broken_links = 0,
		-- ⭐ 新增：悬挂链接统计
		dangling_pairs = 0,
	}

	validate_links("code", all_todo, all_code, summary, verbose)
	validate_links("todo", all_todo, all_code, summary, verbose)

	-- ⭐ 检查悬挂链接对
	local all_ids = {}
	for id, _ in pairs(all_todo) do
		all_ids[id] = true
	end
	for id, _ in pairs(all_code) do
		all_ids[id] = true
	end

	for id, _ in pairs(all_ids) do
		local todo_obj = all_todo[id]
		local code_obj = all_code[id]
		local is_dangling, _ = is_dangling_pair(id, todo_obj, code_obj)
		if is_dangling then
			summary.dangling_pairs = summary.dangling_pairs + 1
			summary.broken_links = summary.broken_links + 1
			if todo_obj then
				summary.broken_links = summary.broken_links + 1
			end
			if code_obj then
				summary.broken_links = summary.broken_links + 1
			end
		end
	end

	if opts.check_verification then
		summary.unverified_todo = 0
		summary.unverified_code = 0
		for _, link_obj in pairs(all_todo) do
			if not link_obj.line_verified then
				summary.unverified_todo = summary.unverified_todo + 1
			end
		end
		for _, link_obj in pairs(all_code) do
			if not link_obj.line_verified then
				summary.unverified_code = summary.unverified_code + 1
			end
		end
	end

	summary.summary = string.format(
		"代码标记: %d, TODO 标记: %d, 孤立代码: %d, 孤立 TODO: %d, 缺失文件: %d, 损坏链接: %d, 悬挂对: %d",
		summary.total_code,
		summary.total_todo,
		summary.orphan_code,
		summary.orphan_todo,
		summary.missing_files,
		summary.broken_links,
		summary.dangling_pairs
	)
	return summary
end

----------------------------------------------------------------------
-- ⭐ 新增：在修复链接时清理悬挂数据
----------------------------------------------------------------------
--- 尝试修复损坏的链接（增强版）
--- @param opts table|nil
--- @return table
function M.repair_links(opts)
	opts = opts or {}
	local verbose = opts.verbose or false
	local dry_run = opts.dry_run or false

	-- ⭐ 先清理悬挂数据（两端都不存在）
	local dangling_report = M.cleanup_dangling_links({
		verbose = verbose,
		dry_run = dry_run,
	})

	-- 重新获取最新的数据（可能已经删除了部分）
	local all_code = link.get_all_code()
	local all_todo = link.get_all_todo()
	local store = require("todo2.store.nvim_store")

	local report = {
		relocated = 0,
		deleted_orphans = 0,
		errors = 0,
		unverified_fixed = 0,
		dangling_deleted = dangling_report.dangling_pairs, -- ⭐ 清理的悬挂对
	}

	-- 修复可重定位的链接
	for _, link_obj in pairs(all_code) do
		local relocated = relocate_link(link_obj, verbose)
		if relocated.path ~= link_obj.path or relocated.line ~= link_obj.line then
			if not dry_run then
				store.set_key("todo.links.code." .. link_obj.id, relocated)
			end
			report.relocated = report.relocated + 1
		end
		if not link_obj.line_verified and relocated.line_verified then
			report.unverified_fixed = report.unverified_fixed + 1
		end
	end

	for _, link_obj in pairs(all_todo) do
		local relocated = relocate_link(link_obj, verbose)
		if relocated.path ~= link_obj.path or relocated.line ~= link_obj.line then
			if not dry_run then
				store.set_key("todo.links.todo." .. link_obj.id, relocated)
			end
			report.relocated = report.relocated + 1
		end
		if not link_obj.line_verified and relocated.line_verified then
			report.unverified_fixed = report.unverified_fixed + 1
		end
	end

	-- 清理孤立链接
	if not dry_run then
		for id in pairs(all_code) do
			if not all_todo[id] then
				link.delete_code(id)
				report.deleted_orphans = report.deleted_orphans + 1
			end
		end
		for id in pairs(all_todo) do
			if not all_code[id] then
				link.delete_todo(id)
				report.deleted_orphans = report.deleted_orphans + 1
			end
		end
	end

	return report
end

----------------------------------------------------------------------
-- 原有的公共 API（保持不变，但增强清理功能）
----------------------------------------------------------------------
--- 清理过期链接（增强版：同时清理悬挂数据）
--- @param days number
--- @return table
function M.cleanup(days)
	local cleaned_todo = cleanup_expired_links("todo", days)
	local cleaned_code = cleanup_expired_links("code", days)

	-- ⭐ 直接调用 trash.auto_cleanup()，它会自己判断是否执行
	local trash = require("todo2.store.trash")
	local trash_report = trash.auto_cleanup() -- auto_cleanup 内部有配置判断

	-- ⭐ 新增：同时清理悬挂数据
	local dangling_report = M.cleanup_dangling_links()

	return {
		expired_todo = cleaned_todo,
		expired_code = cleaned_code,
		expired_total = cleaned_todo + cleaned_code,
		trash_cleaned = (trash_report.deleted_pairs or 0)
			+ (trash_report.deleted_todo or 0)
			+ (trash_report.deleted_code or 0),
		dangling_cleaned = dangling_report.dangling_pairs,
		summary = string.format(
			"清理完成: %d 个过期TODO, %d 个过期代码链接, %d 个软删除链接, %d 个悬挂链接对",
			cleaned_todo,
			cleaned_code,
			(trash_report.deleted_pairs or 0) + (trash_report.deleted_todo or 0) + (trash_report.deleted_code or 0),
			dangling_report.dangling_pairs
		),
	}
end

--- 清理过期归档链接
--- @return number
function M.cleanup_expired_archives()
	local cutoff_time = os.time() - 30 * 86400
	local cleaned = 0
	local archived = link.get_archived_links()
	for id, data in pairs(archived) do
		local archive_time = nil
		if data.todo and data.todo.archived_at then
			archive_time = data.todo.archived_at
		elseif data.code and data.code.archived_at then
			archive_time = data.code.archived_at
		end
		if archive_time and archive_time < cutoff_time then
			if data.todo then
				link.delete_todo(id)
			end
			if data.code then
				link.delete_code(id)
			end
			cleaned = cleaned + 1
		end
	end
	return cleaned
end

----------------------------------------------------------------------
-- ⭐ 新增：检查指定ID列表的悬挂状态
----------------------------------------------------------------------
--- 检查指定ID列表的悬挂状态
--- @param ids string[] ID列表
--- @param opts table|nil 选项
--- @return table 清理报告
function M.check_dangling_by_ids(ids, opts)
	opts = opts or {}
	local dry_run = opts.dry_run or false
	local verbose = opts.verbose or false

	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local report = {
		checked = #ids,
		cleaned = 0,
		details = {},
	}

	for _, id in ipairs(ids) do
		local todo_obj = all_todo[id]
		local code_obj = all_code[id]

		-- 使用已有的判断逻辑
		local is_dangling, reason = is_dangling_pair(id, todo_obj, code_obj)

		if is_dangling then
			if verbose then
				vim.notify(string.format("清理悬挂链接 %s: %s", id, reason), vim.log.levels.DEBUG)
			end

			table.insert(report.details, {
				id = id,
				action = "delete",
				reason = reason,
			})

			if not dry_run then
				if todo_obj then
					link.delete_todo(id)
				end
				if code_obj then
					link.delete_code(id)
				end
			end
			report.cleaned = report.cleaned + 1
		end
	end

	return report
end

return M
