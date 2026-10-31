-- 日历两层语义（承诺 / 活动）+ axis:/start: 过滤回归测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/calendar_axis.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-axis-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
local todo_dir = vim.fn.expand("~/.todo-files/todo2-axis-proj")
vim.fn.delete(todo_dir, "rf")

require("todo2").setup({})

local service = require("todo2.ui.calendar.service")
local flt = require("todo2.render.filter")
local commands = require("todo2.commands")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

vim.fn.mkdir(todo_dir, "p")
vim.fn.writefile({
	"# TODO",
	"",
	"- [ ] todo:ax0001 @2026-10-05 #ship 只有期限",
	"- [ ] todo:ax0002 ~2026-10-06 @2026-10-20 #ship 排期",
	"- [ ] todo:ax0003 ~2026-10-07 只有开始日",
	"- [ ] todo:ax0004 纯标记（无时间维度）",
	"- [x] todo:ax0005 @2026-10-08 已完成的承诺",
}, todo_dir .. "/main.todo.md")

vim.cmd("edit " .. vim.fn.fnameescape(todo_dir .. "/main.todo.md"))
commands.sync_current()
service.invalidate()

---------------------------------------------------------------------
-- 承诺层
---------------------------------------------------------------------
local entries = service.month_entries(2026, 10, { force_refresh = true })
check("deadline lands on its due day", (entries.commits[5] or {})[1] ~= nil and entries.commits[5][1].plan == "deadline")
check("interval lands on due day", (entries.commits[20] or {})[1] ~= nil and entries.commits[20][1].plan == "interval",
	entries.commits[20] and entries.commits[20][1] and entries.commits[20][1].plan)
check("interval keeps start", entries.commits[20] and entries.commits[20][1].start == "2026-10-06",
	entries.commits[20] and entries.commits[20][1] and entries.commits[20][1].start)
check("planned lands on start day", (entries.commits[7] or {})[1] ~= nil and entries.commits[7][1].plan == "planned")
check("completed commitment still counts", #(entries.commits[8] or {}) == 1)

---------------------------------------------------------------------
-- 活动层（时间戳 = 今天，所以不进 2026-10）
---------------------------------------------------------------------
local today = os.date("%Y-%m-%d")
local ty, tmo = today:match("^(%d%d%d%d)%-(%d%d)")
local this_month = service.month_entries(tonumber(ty), tonumber(tmo), { force_refresh = true })
local tday = tonumber(today:sub(9, 10))
local acts = this_month.activities[tday] or {}
check("marks recorded on the day they were touched", #acts >= 4, #acts)
check(
	"pure mark only lives in the activity layer",
	(function()
		for _, item in ipairs(acts) do
			if item.id == "ax0004" then
				return true
			end
		end
		return false
	end)()
)
check(
	"commitment with due in another month still shows activity",
	(function()
		local has_planned = false
		for _, item in ipairs(acts) do
			if item.id == "ax0003" then
				has_planned = true
			end
		end
		return has_planned
	end)()
)

---------------------------------------------------------------------
-- 过滤：axis: / start:
---------------------------------------------------------------------
local commit_only = flt.parse({ "axis:commit" })
local activity_only = flt.parse({ "axis:activity" })
check("axis parsed", commit_only.axis == "commit" and activity_only.axis == "activity")
check("axis:all is the default", flt.parse({ "axis:all" }).axis == nil)
check("unknown axis rejected", (flt.parse({ "axis:nope" })) == nil)
check("describe keeps axis", flt.describe(commit_only) == "axis:commit", flt.describe(commit_only))
check("is_empty sees axis", not flt.is_empty(commit_only))

local with_axis = service.month_entries(2026, 10, { force_refresh = true, spec = commit_only })
check("axis:commit keeps commitments", #(with_axis.commits[5] or {}) == 1)
local without = service.month_entries(2026, 10, { force_refresh = true, spec = activity_only })
check("axis:activity drops commitments from the commit layer", #(without.commits[5] or {}) == 0)

local start_none = flt.parse({ "start:none" })
local no_start = service.month_entries(2026, 10, { force_refresh = true, spec = start_none })
check("start:none keeps deadline-only tasks", #(no_start.commits[5] or {}) == 1)
check("start:none drops planned tasks", #(no_start.commits[7] or {}) == 0)
check("start:none drops intervals", #(no_start.commits[20] or {}) == 0)

local start_before = flt.parse({ "start:<2026-10-07" })
local early = service.month_entries(2026, 10, { force_refresh = true, spec = start_before })
check("start:< keeps the interval", #(early.commits[20] or {}) == 1)
check(
	"start:< drops the planned-on-10-07 task",
	#(early.commits[7] or {}) == 0,
	vim.inspect(vim.tbl_map(function(i)
		return { id = i.id, start = i.start, plan = i.plan }
	end, early.commits[7] or {}))
)

check("named round-trip keeps start/axis", vim.deep_equal(flt.parse({ "start:none", "axis:commit" }), flt.from_table(flt.to_table(flt.parse({ "start:none", "axis:commit" })))))

---------------------------------------------------------------------
-- 显示：两层徽章 + 图例
---------------------------------------------------------------------
local view = require("todo2.ui.calendar.view")
local lines, layout = view.build_month_lines(2026, 10, entries)
check("legend mentions both layers", lines[#lines]:find("commit", 1, true) ~= nil and lines[#lines]:find("mark", 1, true) ~= nil, lines[#lines])
local geo5
for _, row in ipairs(layout.rows) do
	for _, geo in ipairs(row.cells) do
		if not geo5 then
			geo5 = geo
		end
	end
end
check("cells expose commit/mark badge offsets", geo5 ~= nil)

print(string.format("\n%s (%d failed)", fails == 0 and "ALL PASS" or "FAILURES", fails))
os.exit(fails == 0 and 0 or 1)
