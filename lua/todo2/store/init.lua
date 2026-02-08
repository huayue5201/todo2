-- lua/todo2/store/init.lua
-- 存储模块主入口，统一导出所有功能

local M = {}

---------------------------------------------------------------------
-- 模块导出
---------------------------------------------------------------------

-- 基础模块
M.link = require("todo2.store.link")
M.index = require("todo2.store.index")
M.types = require("todo2.store.types")
M.meta = require("todo2.store.meta")

-- 清理功能
M.cleanup = require("todo2.store.cleanup")

-- 工具模块
M.locator = require("todo2.store.locator") -- 现在包含上下文定位功能
M.context = require("todo2.store.context")
M.consistency = require("todo2.store.consistency")
M.state_machine = require("todo2.store.state_machine")
M.autofix = require("todo2.store.autofix")
M.utils = require("todo2.store.utils")

-- 新增模块（除了 context_locator）
M.trash = require("todo2.store.trash")
M.verification = require("todo2.store.verification")
M.conflict = require("todo2.store.conflict")
M.config = require("todo2.store.config")

-- 存储后端
M.nvim_store = require("todo2.store.nvim_store")

---------------------------------------------------------------------
-- 简化API（向前兼容）
---------------------------------------------------------------------

--- 获取所有代码链接（简化调用）
--- @return table<string, table>
function M.get_all_code_links()
	return M.link.get_all_code()
end

--- 获取所有TODO链接（简化调用）
--- @return table<string, table>
function M.get_all_todo_links()
	return M.link.get_all_todo()
end

--- 获取项目根目录
--- @return string
function M.get_project_root()
	return M.meta.get_project_root()
end

--- 验证所有链接
--- @param opts table|nil
--- @return table
function M.validate_all_links(opts)
	return M.cleanup.validate_all(opts)
end

--- 尝试修复链接
--- @param opts table|nil
--- @return table
function M.repair_links(opts)
	return M.cleanup.repair_links(opts)
end

--- 清理过期链接
--- @param days number
--- @return number
function M.cleanup_expired(days)
	local result = M.cleanup.cleanup(days)
	return result.expired_total or 0
end

--- 清理已完成链接
--- @param days number|nil
--- @return number
function M.cleanup_completed(days)
	return M.cleanup.cleanup_completed(days)
end

---------------------------------------------------------------------
-- 新增简化API
---------------------------------------------------------------------

--- 恢复软删除的链接
--- @param id string 链接ID
--- @param link_type string|nil "todo", "code" 或 nil（两者都恢复）
--- @return boolean 是否成功
function M.restore_link(id, link_type)
	return M.trash.restore(id, link_type)
end

--- 获取回收站内容
--- @param days number|nil 天数限制，nil表示所有
--- @return table 回收站链接
function M.get_trash(days)
	return M.trash.get_trash(days)
end

--- 清空回收站（永久删除所有软删除的链接）
--- @param days number|nil 删除多少天前的，nil表示全部
--- @return table 清理报告
function M.empty_trash(days)
	return M.trash.empty_trash(days)
end

--- 验证单个链接
--- @param id string 链接ID
--- @param link_type string|nil "todo", "code" 或 nil（两者都验证）
--- @param force boolean 是否强制重新验证
--- @return table 验证结果
function M.verify_link(id, link_type, force)
	return M.verification.verify_link(id, link_type, force or false)
end

--- 批量验证所有链接
--- @param opts table|nil 选项
--- @return table 验证报告
function M.verify_all_links(opts)
	return M.verification.verify_all(opts)
end

--- 获取未验证的链接
--- @param days number|nil 天数限制，nil表示所有
--- @return table 未验证链接列表
function M.get_unverified_links(days)
	return M.verification.get_unverified_links(days)
end

--- 更新链接的上下文信息（现在通过 locator 模块）
--- @param id string 链接ID
--- @param link_type string|nil "todo", "code" 或 nil（两者都更新）
--- @return table|nil 更新后的链接
function M.update_link_context(id, link_type)
	local locator = require("todo2.store.locator")
	local link_module = require("todo2.store.link")
	local store = require("todo2.store.nvim_store")
	local types = require("todo2.store.types")

	local LINK_TYPE_CONFIG = {
		todo = "todo.links.todo.",
		code = "todo.links.code.",
	}

	if link_type == "todo" or not link_type then
		local link = link_module.get_todo(id)
		if link then
			link = locator.update_context(link)
			store.set_key(LINK_TYPE_CONFIG.todo .. id, link)
			return link
		end
	end

	if link_type == "code" or not link_type then
		local link = link_module.get_code(id)
		if link then
			link = locator.update_context(link)
			store.set_key(LINK_TYPE_CONFIG.code .. id, link)
			return link
		end
	end

	return nil
end

--- 获取上下文匹配统计（现在通过 locator 模块）
--- @return table 统计信息
function M.get_context_stats()
	local locator = require("todo2.store.locator")
	return locator.get_context_stats()
end

--- 检测链接冲突
--- @param id string 链接ID
--- @return table 冲突检测结果
function M.detect_conflict(id)
	return M.conflict.detect_conflict(id)
end

--- 解决链接冲突
--- @param id string 链接ID
--- @param resolution table 解决策略
--- @return table 解决结果
function M.resolve_conflict(id, resolution)
	return M.conflict.resolve_conflict(id, resolution)
end

--- 批量检测所有冲突
--- @return table 冲突报告
function M.detect_all_conflicts()
	return M.conflict.detect_all_conflicts()
end

--- 初始化配置和启动后台任务
--- @param user_config table|nil 用户自定义配置
function M.setup(user_config)
	-- 加载默认配置
	M.config.load()

	-- 合并用户配置
	if user_config then
		M.config.update(user_config)
	end

	-- 初始化元数据
	M.meta.init()

	-- 启动自动验证（如果启用）
	if M.config.get("verification.enabled") then
		M.verification.setup_auto_verification(M.config.get("verification.auto_verify_interval"))
	end

	return true
end

--- 获取配置
--- @param key string|nil 配置键，nil返回全部
--- @return any 配置值
function M.get_config(key)
	return M.config.get(key)
end

--- 设置配置
--- @param key string 配置键
--- @param value any 配置值
function M.set_config(key, value)
	return M.config.set(key, value)
end

--- 获取系统状态报告
--- @return table 状态报告
function M.get_status_report()
	local report = {
		meta = M.meta.get_stats(),
		verification = M.verification.get_stats(),
		context = M.locator.get_context_stats(),
		trash = {},
		conflicts = {},
	}

	-- 获取回收站统计
	local trash = M.get_trash()
	local todo_count = 0
	local code_count = 0
	local pairs_count = 0

	for _ in pairs(trash.todo) do
		todo_count = todo_count + 1
	end

	for _ in pairs(trash.code) do
		code_count = code_count + 1
	end

	for _ in pairs(trash.pairs) do
		pairs_count = pairs_count + 1
	end

	report.trash = {
		todo = todo_count,
		code = code_count,
		pairs = pairs_count,
	}

	-- 获取冲突统计
	local conflict_report = M.detect_all_conflicts()
	report.conflicts = {
		total = conflict_report.conflicts_found or 0,
		todo = conflict_report.todo_conflicts or 0,
		code = conflict_report.code_conflicts or 0,
		pair = conflict_report.pair_conflicts or 0,
	}

	-- 计算整体健康度
	local total_links = report.meta.total_links or 0
	local verified_links = report.verification.verified_links or 0
	local unverified_links = report.verification.unverified_links or 0

	report.health = {
		verification_rate = total_links > 0 and math.floor((verified_links / total_links) * 100) or 0,
		unverified_rate = total_links > 0 and math.floor((unverified_links / total_links) * 100) or 0,
		conflict_rate = total_links > 0 and math.floor((report.conflicts.total / total_links) * 100) or 0,
		trash_rate = total_links > 0 and math.floor(((todo_count + code_count) / total_links) * 100) or 0,
	}

	-- 健康度评级
	local health_score = 100
	health_score = health_score - report.health.unverified_rate * 0.5
	health_score = health_score - report.health.conflict_rate
	health_score = health_score - report.health.trash_rate * 0.2

	report.health.score = math.max(0, math.min(100, math.floor(health_score)))

	if report.health.score >= 80 then
		report.health.level = "健康"
	elseif report.health.score >= 60 then
		report.health.level = "一般"
	else
		report.health.level = "需要维护"
	end

	return report
end

--- 一键维护：运行所有清理和修复操作
--- @param opts table|nil 选项
--- @return table 维护报告
function M.run_maintenance(opts)
	opts = opts or {}
	local report = {
		timestamp = os.time(),
		steps = {},
	}

	-- 1. 验证所有链接
	table.insert(report.steps, {
		name = "验证链接",
		result = M.verify_all_links({ show_progress = false }),
	})

	-- 2. 修复损坏的链接
	table.insert(report.steps, {
		name = "修复链接",
		result = M.repair_links({ verbose = false, dry_run = false }),
	})

	-- 3. 清理过期链接（30天）
	table.insert(report.steps, {
		name = "清理过期链接",
		result = M.cleanup.cleanup(30),
	})

	-- 4. 清理回收站（如果启用）
	if M.config.get("trash.enabled") and M.config.get("trash.auto_cleanup") then
		table.insert(report.steps, {
			name = "清理回收站",
			result = M.trash.auto_cleanup(),
		})
	end

	-- 5. 检测并解决冲突
	table.insert(report.steps, {
		name = "冲突检测",
		result = M.detect_all_conflicts(),
	})

	-- 汇总报告
	local total_fixed = 0
	local total_cleaned = 0

	for _, step in ipairs(report.steps) do
		if step.result.relocated then
			total_fixed = total_fixed + (step.result.relocated or 0)
		end
		if step.result.expired_total then
			total_cleaned = total_cleaned + (step.result.expired_total or 0)
		end
		if step.result.deleted_pairs then
			total_cleaned = total_cleaned + (step.result.deleted_pairs or 0)
		end
		if step.result.cleaned then
			total_cleaned = total_cleaned + (step.result.cleaned or 0)
		end
	end

	report.summary =
		string.format("维护完成: 修复了 %d 个链接, 清理了 %d 个链接", total_fixed, total_cleaned)

	return report
end

--- 导出所有数据（用于备份）
--- @return table 导出的数据
function M.export_data()
	local data = {
		version = "2.0",
		export_time = os.time(),
		meta = M.meta.get(),
		links = {
			todo = {},
			code = {},
		},
		config = M.config.get(),
	}

	-- 导出所有TODO链接（包括已删除的）
	local all_todo = M.link.get_all_todo_including_deleted()
	for id, link in pairs(all_todo) do
		data.links.todo[id] = link
	end

	-- 导出所有代码链接（包括已删除的）
	local all_code = M.link.get_all_code_including_deleted()
	for id, link in pairs(all_code) do
		data.links.code[id] = link
	end

	return data
end

--- 导入数据（从备份恢复）
--- @param data table 要导入的数据
--- @param opts table|nil 选项
--- @return table 导入结果
function M.import_data(data, opts)
	opts = opts or {}
	local overwrite = opts.overwrite or false
	local merge = opts.merge or false

	local result = {
		imported_todo = 0,
		imported_code = 0,
		skipped_todo = 0,
		skipped_code = 0,
		errors = 0,
	}

	-- 验证数据格式
	if not data or not data.links or not data.links.todo or not data.links.code then
		result.error = "无效的数据格式"
		return result
	end

	-- 导入TODO链接
	for id, link in pairs(data.links.todo) do
		local existing = M.link.get_todo(id)

		if existing and not overwrite and not merge then
			result.skipped_todo = result.skipped_todo + 1
		else
			if merge and existing then
				-- 合并模式：只更新缺失的字段
				for k, v in pairs(link) do
					if existing[k] == nil then
						existing[k] = v
					end
				end
				existing.updated_at = os.time()
				M.nvim_store.set_key("todo.links.todo." .. id, existing)
			else
				-- 覆盖模式或新链接
				M.nvim_store.set_key("todo.links.todo." .. id, link)

				-- 重建文件索引
				local index = require("todo2.store.index")
				index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)
			end

			result.imported_todo = result.imported_todo + 1
		end
	end

	-- 导入代码链接
	for id, link in pairs(data.links.code) do
		local existing = M.link.get_code(id)

		if existing and not overwrite and not merge then
			result.skipped_code = result.skipped_code + 1
		else
			if merge and existing then
				-- 合并模式：只更新缺失的字段
				for k, v in pairs(link) do
					if existing[k] == nil then
						existing[k] = v
					end
				end
				existing.updated_at = os.time()
				M.nvim_store.set_key("todo.links.code." .. id, existing)
			else
				-- 覆盖模式或新链接
				M.nvim_store.set_key("todo.links.code." .. id, link)

				-- 重建文件索引
				local index = require("todo2.store.index")
				index._add_id_to_file_index("todo.index.file_to_code", link.path, id)
			end

			result.imported_code = result.imported_code + 1
		end
	end

	-- 更新元数据
	if data.meta then
		M.meta.update(data.meta)
	end

	-- 更新配置
	if data.config then
		M.config.update(data.config)
	end

	result.summary =
		string.format("导入完成: %d 个TODO链接, %d 个代码链接", result.imported_todo, result.imported_code)

	return result
end

--- 重置系统（清除所有数据，用于测试）
--- @param confirm boolean 确认标志，必须为true
--- @return boolean 是否成功
function M.reset_system(confirm)
	if not confirm then
		vim.notify("重置系统需要确认，请传递 confirm=true", vim.log.levels.ERROR)
		return false
	end

	vim.notify("正在重置系统...", vim.log.levels.WARN)

	-- 清除所有存储键
	local store = M.nvim_store.get()
	local all_keys = store:namespace_keys("todo")

	for _, key in ipairs(all_keys) do
		store:delete(key)
	end

	-- 重置配置
	M.config.reset()

	-- 重新初始化元数据
	M.meta.init()

	vim.notify("系统已重置", vim.log.levels.INFO)
	return true
end

return M
