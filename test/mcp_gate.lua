-- test/mcp_gate.lua —— MCP 接入点默认不发布；ai.enabled = true 才在 setup 时发布
-- 运行：nvim --headless -u NONE -l test/mcp_gate.lua

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

-- 1. 默认配置：不发布
require("todo2").setup()
check(vim.fn.filereadable(addr_file) == 0, "default config does not publish an MCP endpoint")

-- 2. 默认值本身是关闭的
check(require("todo2.config").get("ai.enabled") == false, "ai.enabled defaults to false")

-- 3. :TodoContext 这类纯本地能力不依赖 ai.enabled
local ctx = require("todo2.ai")
check(type(ctx.build) == "function" or type(ctx.list) == "function", "todo2.ai still loads for :TodoContext")

-- 4. 显式开启后发布
require("todo2.config").set("ai.enabled", true)
require("todo2.mcp").publish()
check(vim.fn.filereadable(addr_file) == 1, "ai.enabled = true publishes an MCP endpoint")

print("")
if failures == 0 then
	print("ALL PASS (" .. checks .. " checks)")
else
	print(failures .. " FAILED of " .. checks)
	os.exit(1)
end
