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
	local all_todo = link.get_all_todo()
	local ids = vim.tbl_keys(all_todo)
	local index = 1
	local report = { cleaned = 0, checked = 0 }

	local function process_next()
		if index > #ids then
			if on_done then
				on_done(report)
			end
			return
		end

		local id = ids[index]
		local obj = all_todo[id]

		-- 调用上面重构的异步定位
		M.locate_by_context(obj.path, obj, function(found)
			if not found then
				-- 真正找不到才清理
				link.delete_todo(id)
				report.cleaned = report.cleaned + 1
			end
			report.checked = report.checked + 1
			index = index + 1
			process_next() -- 处理下一个
		end)
	end

	process_next()
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
