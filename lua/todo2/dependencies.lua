-- lua/todo2/dependencies.lua
--- @brief 依赖检查与管理模块

local M = {}

---------------------------------------------------------------------
-- 必需依赖列表
---------------------------------------------------------------------
M.required_dependencies = {
	{
		name = "nvim-store3",
		url = "https://github.com/yourname/nvim-store3",
		message = "todo2 requires the nvim-store3 plugin",
	},
}

---------------------------------------------------------------------
-- 可选依赖列表
---------------------------------------------------------------------
M.optional_dependencies = {
	-- 这里可以添加可选依赖
}

---------------------------------------------------------------------
-- 检查所有依赖
---------------------------------------------------------------------
function M.check()
	local missing = {}
	local warnings = {}

	-- 检查必需依赖
	for _, dep in ipairs(M.required_dependencies) do
		local ok, _ = pcall(require, dep.name)
		if not ok then
			table.insert(missing, dep)
		end
	end

	-- 检查可选依赖
	for _, dep in ipairs(M.optional_dependencies) do
		local ok, _ = pcall(require, dep.name)
		if not ok then
			table.insert(warnings, dep)
		end
	end

	return {
		all_satisfied = #missing == 0,
		missing = missing,
		warnings = warnings,
	}
end

---------------------------------------------------------------------
-- 初始化依赖
---------------------------------------------------------------------
function M.check_and_init()
	local result = M.check()

	-- 如果有缺失的必需依赖
	if not result.all_satisfied then
		local error_msg = "Missing required dependencies:\n"
		for _, dep in ipairs(result.missing) do
			error_msg = error_msg .. string.format("- %s: %s\n", dep.name, dep.message)
			error_msg = error_msg .. string.format("  Please install: %s\n", dep.url)
		end
		return false, error_msg
	end

	-- 初始化 nvim-store3（如果存在）
	local has_nvim_store3, nvim_store3 = pcall(require, "nvim-store3")
	if has_nvim_store3 then
		nvim_store3.global({
			storage = {
				backend = "json",
				flush_delay = 1000,
			},
		})
	end

	-- 如果有可选的依赖缺失，发出警告
	if #result.warnings > 0 then
		local warning_msg = "Optional dependencies missing (features may be limited):\n"
		for _, dep in ipairs(result.warnings) do
			warning_msg = warning_msg .. string.format("- %s: %s\n", dep.name, dep.message or "")
		end
		vim.notify(warning_msg, vim.log.levels.WARN)
	end

	return true, "All dependencies satisfied"
end

return M
