-- test/mcp_gate.lua —— MCP 接入点的发布开关（mcp.publish）与已废弃 ai.enabled 的解耦
-- 运行：nvim --headless -u NONE -l test/mcp_gate.lua
--
-- 覆盖：
--   默认不发布 / 默认值本身关闭 /
--   mcp.publish 开关发布 / 显式 mcp.publish=false 覆盖 ai.enabled=true /
--   ai.enabled=true 仍作向后兼容（并标记 deprecated）/
--   :TodoContext 这类纯本地能力不依赖任一开关。

local failures, checks = 0, 0
local function check(cond, msg)
	checks = checks + 1
	if cond then
		print("PASS " .. msg)
	else
		failures = failures + 1
		print("FAIL " .. msg)
	end
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/../nvim-store3")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.cmd("cd " .. dir)

local addr_file = vim.fn.stdpath("cache") .. "/todo2/nvim.addr"
-- 从干净状态开始：这个地址文件是共享的旧兜底文件（MCP 桥已不再读它），
-- 上一次运行或其它实例可能留下残留，会让「setup 是否发布」的判断失真。
vim.fn.delete(addr_file)
local config = require("todo2.config")
local mcp = require("todo2.mcp")

-- 1. 默认配置：不发布
require("todo2").setup()
check(vim.fn.filereadable(addr_file) == 0, "default config does not publish an MCP endpoint")

-- 2. 默认值本身是关闭的，且 ai.enabled 不再参与
check(config.get("mcp.publish") == nil, "mcp.publish has no baked-in default (nil = fall back)")
check(config.get("ai.enabled") == false, "ai.enabled defaults to false")
check(mcp.publish_enabled() == false, "publish_enabled() is false by default")
check(mcp.using_deprecated_publish_key() == false, "no deprecated key in use by default")

-- 3. :TodoContext 这类纯本地能力不依赖任一开关
local ctx = require("todo2.ai")
check(type(ctx.build) == "function" or type(ctx.list) == "function", "todo2.ai still loads for :TodoContext")

-- 4. 新键生效：mcp.publish = true
config.set("mcp.publish", true)
check(mcp.publish_enabled() == true, "mcp.publish = true enables publishing")
check(mcp.using_deprecated_publish_key() == false, "mcp.publish does not count as deprecated usage")
mcp.publish()
check(vim.fn.filereadable(addr_file) == 1, "mcp.publish = true publishes an MCP endpoint")

-- 5. 新键优先：显式 mcp.publish = false 压过已废弃的 ai.enabled = true
config.set("ai.enabled", true)
config.set("mcp.publish", false)
check(mcp.publish_enabled() == false, "explicit mcp.publish = false overrides ai.enabled = true")
check(mcp.using_deprecated_publish_key() == false, "explicit mcp.publish suppresses the deprecation notice")

-- 6. 向后兼容：只有 ai.enabled = true 时仍发布（但被标记为 deprecated）
config.current.mcp.publish = nil -- 直接改内存，表示「用户没写过这个键」
check(config.get("mcp.publish") == nil, "mcp.publish can be unset (nil)")
check(mcp.publish_enabled() == true, "deprecated ai.enabled = true still publishes (back-compat)")
check(mcp.using_deprecated_publish_key() == true, "deprecated usage is reported")

print("")
if failures == 0 then
	print("ALL PASS (" .. checks .. " checks)")
else
	print(failures .. " FAILED of " .. checks)
	os.exit(1)
end
