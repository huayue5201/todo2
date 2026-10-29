-- 到期日（due）字段回归测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/due.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local due = require("todo2.utils.due")
local format = require("todo2.utils.format")
local filter = require("todo2.render.filter")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

---------------------------------------------------------------------
-- 日期合法性 / 归一化
---------------------------------------------------------------------
check("valid date", due.is_date("2026-07-01"))
check("invalid day", not due.is_date("2026-02-30"))
check("invalid month", not due.is_date("2026-13-01"))
check("invalid shape", not due.is_date("2026/07/01"))
check("leap day", due.is_date("2024-02-29") and not due.is_date("2026-02-29"))

check("normalize slashes", due.normalize("2026/07/01") == "2026-07-01")
check("normalize dense", due.normalize("20260701") == "2026-07-01")
check("normalize today", due.normalize("today") == due.today())
check("normalize tomorrow", due.normalize("tomorrow") == due.add_days(due.today(), 1))
check("normalize +7d", due.normalize("+7d") == due.add_days(due.today(), 7))
check("normalize -1", due.normalize("-1") == due.add_days(due.today(), -1))
check("normalize junk", due.normalize("nope") == nil)

local today = due.today()
check("add_days month cross", due.add_days("2026-01-31", 1) == "2026-02-01")
check("add_days back cross", due.add_days("2026-03-01", -1) == "2026-02-28")

---------------------------------------------------------------------
-- 行内语法
---------------------------------------------------------------------
local parsed = format.parse_task_line("- [ ] todo:ab12cd @2026-07-01 #fix 修登录")
check("parse due", parsed and parsed.due == "2026-07-01")
check("parse tags after due", parsed and #parsed.tags == 1 and parsed.tags[1] == "fix")
check("parse content after due", parsed and parsed.content == "修登录")

local line = format.format_task_line({
	indent = "",
	checkbox = "[ ]",
	id = "ab12cd",
	status = "todo",
	due = "2026-07-01",
	tags = { "fix" },
	content = "修登录",
})
check("format roundtrip", line == "- [ ] todo:ab12cd @2026-07-01 #fix 修登录", line)

local re = format.parse_task_line(line)
check("roundtrip due", re and re.due == "2026-07-01")

local no_due = format.parse_task_line("- [ ] todo:ab12cd #fix no due here")
check("no due ok", no_due and no_due.due == nil and #no_due.tags == 1)

-- 非法日期退化为普通文本，不吞内容
local bad = format.parse_task_line("- [ ] todo:ab12cd @2026-02-30 #fix x")
check("bad date kept as text", bad and bad.due == nil and bad.content:find("@2026%-02%-30") ~= nil)

---------------------------------------------------------------------
-- 紧迫度
---------------------------------------------------------------------
local yesterday = due.add_days(today, -1)
local soon = due.add_days(today, 2)
local later = due.add_days(today, 30)
check("urgency overdue", due.urgency(yesterday, "todo") == "overdue")
check("urgency today", due.urgency(today, "todo") == "today")
check("urgency soon", due.urgency(soon, "todo") == "soon")
check("urgency future", due.urgency(later, "todo") == "future")
check("urgency completed none", due.urgency(yesterday, "completed") == nil)
check("hl overdue", due.hl(yesterday, "todo") == "TodoDueOverdue")

---------------------------------------------------------------------
-- 筛选条件
---------------------------------------------------------------------
local dspec = due.parse_spec("today")
check("spec today hits", due.hit(today, dspec, "todo"))
check("spec today misses", not due.hit(yesterday, dspec, "todo"))

check("spec overdue", due.hit(yesterday, due.parse_spec("overdue"), "todo"))
check("spec overdue ignores done", not due.hit(yesterday, due.parse_spec("overdue"), "completed"))

local month_begin = today:sub(1, 7) .. "-01"
check("spec month", due.hit(month_begin, due.parse_spec("month"), "todo"))

local week_spec = due.parse_spec("week")
check("spec week hits today", due.hit(today, week_spec, "todo"))
check("spec week misses far", not due.hit(due.add_days(today, 60), week_spec, "todo"))

check("spec none", due.hit(nil, due.parse_spec("none"), "todo") and not due.hit(today, due.parse_spec("none"), "todo"))
check("spec cmp <", due.hit(yesterday, due.parse_spec("<" .. today), "todo"))
check("spec cmp >= ", due.hit(today, due.parse_spec(">=" .. today), "todo"))
check("spec bad", due.parse_spec("someday") == nil)

local fspec, ferr = filter.parse({ "due:overdue", "#fix" })
check("filter parse due", fspec ~= nil and fspec.due ~= nil, ferr)
check("filter describe due", filter.describe(fspec):find("due:overdue", 1, true) ~= nil)
check("filter is_empty", not filter.is_empty(fspec))
check("filter table roundtrip", filter.to_table(fspec).due == "overdue")

local back = filter.from_table(filter.to_table(fspec))
check("filter from_table due", back and back.due and back.due.kind == "overdue")

local bad_spec, bad_err = filter.parse({ "due:someday" })
check("filter bad due errors", bad_spec == nil and bad_err ~= nil)

print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
