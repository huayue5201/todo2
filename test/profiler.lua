-- 性能插桩测试：默认零开销、开启后累计、报告排序（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/profiler.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local fails, total = 0, 0
local function check(name, cond, extra)
	total = total + 1
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local config = require("todo2.config")
local profiler = require("todo2.utils.profiler")

---------------------------------------------------------------------
-- 1) 关闭时：透传、多返回值、不记账
---------------------------------------------------------------------
config.setup({})
profiler.setup()
check("disabled by default", profiler.enabled() == false)

local a, b = profiler.measure("x", function(x) return x + 1, x + 2 end, 1)
check("disabled: passes return values through", a == 2 and b == 3)
check("disabled: nothing recorded", #profiler.report() == 0)

---------------------------------------------------------------------
-- 2) 开启后：累计次数与耗时可读
---------------------------------------------------------------------
config.setup({ profile = { enabled = true } })
profiler.setup()
check("enabled by config", profiler.enabled() == true)

for _ = 1, 3 do
	profiler.measure("fast", function() end)
end
profiler.measure("slow", function()
	local deadline = vim.uv.hrtime() + 5e6
	while vim.uv.hrtime() < deadline do
	end
end)

local report = profiler.report()
check("report: one line per label", #report == 2, table.concat(report, " | "))
check("report: counts the calls", report[2]:match("fast%s+n=3") ~= nil or report[1]:match("fast%s+n=3") ~= nil, report[1])
check("report: sorted by total time (slow first)", report[1]:match("^slow") ~= nil, report[1])

---------------------------------------------------------------------
-- 3) 错误照常抛出（插桩不能吞异常）
---------------------------------------------------------------------
local ok, err = pcall(profiler.measure, "boom", function()
	error("explode", 0)
end)
check("errors propagate", ok == false and tostring(err):match("explode") ~= nil, tostring(err))

---------------------------------------------------------------------
-- 4) reset 清空
---------------------------------------------------------------------
profiler.reset()
check("reset: report is empty", #profiler.report() == 0)

print(fails == 0 and string.format("\nALL PASS (%d checks)", total) or string.format("\n%d/%d FAILED", fails, total))
if fails > 0 then
	os.exit(1)
end
