-- lua/todo2/utils/profiler.lua
-- 轻量计时器：给「启动对账、单文件同步、抽屉渲染」这类会卡住用户的路径量一下耗时。
--
-- 关闭时（默认）`measure` 直接透传，零开销；开启后只累计，不影响任何逻辑。
-- 用法：todo2.setup({ profile = { enabled = true } })，然后 `:TodoProfile` 看结果。

local M = {}

---@class todo2.ProfilerStat
---@field count integer 调用次数
---@field total number 累计毫秒
---@field max number 单次最长毫秒

---@type table<string, todo2.ProfilerStat>
local stats = {}
local enabled = false

---读取配置开关（config.setup 之后调用）
function M.setup()
	local config = require("todo2.config")
	enabled = config.get("profile.enabled") == true
	if not enabled then
		stats = {}
	end
end

---@return boolean
function M.enabled()
	return enabled
end

---计时执行 fn(...)，原样返回其结果（含多返回值）
---@param label string 统计项名称
---@param fn function
---@return any ...
function M.measure(label, fn, ...)
	if not enabled then
		return fn(...)
	end

	local started = vim.uv.hrtime()
	local results = { pcall(fn, ...) }
	local elapsed = (vim.uv.hrtime() - started) / 1e6

	local ok = table.remove(results, 1)
	local stat = stats[label]
	if not stat then
		stat = { count = 0, total = 0, max = 0 }
		stats[label] = stat
	end
	stat.count = stat.count + 1
	stat.total = stat.total + elapsed
	stat.max = math.max(stat.max, elapsed)

	if not ok then
		error(results[1], 0)
	end
	return unpack(results)
end

---清空累计
function M.reset()
	stats = {}
end

---@return string[] 每个统计项一行，按累计耗时降序
function M.report()
	local names = vim.tbl_keys(stats)
	table.sort(names, function(a, b)
		return stats[a].total > stats[b].total
	end)

	local lines = {}
	for _, name in ipairs(names) do
		local stat = stats[name]
		table.insert(
			lines,
			string.format("%-22s n=%-5d avg=%6.2fms max=%6.2fms", name, stat.count, stat.total / stat.count, stat.max)
		)
	end
	return lines
end

return M
