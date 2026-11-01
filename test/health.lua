-- lua/todo2/health.lua 的回归测试（headless，自包含）。
-- 运行：./scripts/test.sh health
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local fails = 0
local function check(name, cond, detail)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (detail and (" — " .. tostring(detail)) or ""))
	end
end

-- 独立的项目目录与数据目录，避免污染真实环境
local proj = "/tmp/todo2-health-proj"
vim.fn.mkdir(proj, "p")
vim.cmd("cd " .. proj)

require("todo2").setup()

-- 收集 health 输出（不真的打开 checkhealth 缓冲区）
local function collect()
	local out = {}
	local saved = {}
	for _, level in ipairs({ "start", "ok", "warn", "error", "info" }) do
		saved[level] = vim.health[level]
		vim.health[level] = function(msg)
			out[#out + 1] = { level = level, msg = tostring(msg) }
		end
	end
	local ok, err = pcall(function()
		require("todo2.health").check()
	end)
	for level, fn in pairs(saved) do
		vim.health[level] = fn
	end
	return out, ok, err
end

local out, ok, err = collect()

check("check() runs without error", ok, err)
check("emits at least one section header", #out > 0 and out[1].level == "start", #out and out[1] and out[1].level)

local function find_level(fragment)
	for _, entry in ipairs(out) do
		if entry.msg:find(fragment, 1, true) then
			return entry.level
		end
	end
	return nil
end

check("reports the Neovim + vim.async state", find_level("vim.async") ~= nil)
check("reports the nvim-store3 dependency", find_level("nvim-store3") ~= nil)
check("reports the load path", find_level("loaded from:") == "info")
check("reports the store directory", find_level("store directory") ~= nil)
check("reports the TODO file patterns", find_level("TODO files:") ~= nil)
check("reports MCP publish state", find_level("MCP endpoint:") == "info")
check("MCP state names the mcp.publish key", find_level("mcp = { publish") ~= nil)
check("reports Treesitter parsers", find_level("Treesitter parsers") ~= nil)

-- 解耦回归：ai.enabled 只剩向后兼容语义，且在 checkhealth 里被标为 deprecated
do
	local cfg = require("todo2.config")
	local saved_ai, saved_mcp = cfg.current.ai.enabled, cfg.current.mcp.publish
	cfg.current.ai.enabled = true
	cfg.current.mcp.publish = nil
	local dep = collect()
	local found = false
	for _, entry in ipairs(dep) do
		if entry.msg:find("deprecated ai.enabled", 1, true) then
			found = true
		end
	end
	check("flags the deprecated ai.enabled in checkhealth", found)
	cfg.current.ai.enabled, cfg.current.mcp.publish = saved_ai, saved_mcp
end

-- 没装 nvim-store3 时必须给出 error（而不是静默通过）。
-- 手段：让 require("nvim-store3") 真的失败（package.preload 优先于 rtp）
package.loaded["nvim-store3"] = nil
package.preload["nvim-store3"] = function()
	error("simulated missing dependency")
end

out = {}
for _, level in ipairs({ "start", "ok", "warn", "error", "info" }) do
	vim.health[level] = function(msg)
		out[#out + 1] = { level = level, msg = tostring(msg) }
	end
end
package.loaded["todo2.health"] = nil
pcall(function()
	require("todo2.health").check()
end)
package.preload["nvim-store3"] = nil
package.loaded["todo2.health"] = nil

local missing_reported = false
for _, entry in ipairs(out) do
	if entry.level == "error" and entry.msg:find("nvim-store3 is missing", 1, true) then
		missing_reported = true
	end
end
check("missing nvim-store3 is reported as error", missing_reported)

---------------------------------------------------------------------
if fails == 0 then
	print("\nALL PASS")
else
	print(string.format("\n%d FAILED", fails))
	vim.cmd("cquit")
end
