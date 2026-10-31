-- 行语法里的 start（`~YYYY-MM-DD`）：解析 / 生成 / 前后位置回归测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/format_start.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local format = require("todo2.utils.format")
local due = require("todo2.utils.due")
local schema = require("todo2.store.schema")

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
-- 解析
---------------------------------------------------------------------
local line = "- [ ] todo:aa0001 ~2026-10-20 @2026-10-25 #fix 写点东西"
local parsed = format.parse_task_line(line)
check("id parsed", parsed.id == "aa0001", parsed.id)
check("start parsed", parsed.start == "2026-10-20", parsed.start)
check("due parsed after start", parsed.due == "2026-10-25", parsed.due)
check("tags still parsed", #parsed.tags == 1 and parsed.tags[1] == "fix", vim.inspect(parsed.tags))
check("content has no dates", parsed.content == "写点东西", parsed.content)

local only_start = format.parse_task_line("- [ ] todo:aa0002 ~2026-10-20 只有开始日")
check("start only", only_start.start == "2026-10-20" and only_start.due == nil, vim.inspect(only_start))
check("start only content", only_start.content == "只有开始日", only_start.content)

local only_due = format.parse_task_line("- [ ] todo:aa0003 @2026-10-25 只有截止日")
check("due only", only_due.due == "2026-10-25" and only_due.start == nil)

-- 顺序颠倒（due 在前）：start 不是紧跟标记，所以按「正文里的 @/~」处理
local reversed = format.parse_task_line("- [ ] todo:aa0004 @2026-10-25 ~2026-10-20 顺序颠倒")
check("due-first line keeps start out of the fields", reversed.start == nil, vim.inspect(reversed))
check("due-first line keeps due", reversed.due == "2026-10-25")
check(
	"due-first line keeps the tilde in content",
	reversed.content:find("~2026-10-20", 1, true) ~= nil,
	reversed.content
)

---------------------------------------------------------------------
-- 生成（幂等：写回去再解析要一样）
---------------------------------------------------------------------
local built = format.format_task_line({
	id = "aa0005",
	start = "2026-10-20",
	due = "2026-10-25",
	tags = { "fix", "backend" },
	content = "顺序固定",
	status = "todo",
	indent = "",
})
check(
	"generated line puts start before due",
	built == "- [ ] todo:aa0005 ~2026-10-20 @2026-10-25 #backend #fix 顺序固定",
	built
)
local reparsed = format.parse_task_line(built)
check("round-trip id", reparsed.id == "aa0005")
check("round-trip start/due", reparsed.start == "2026-10-20" and reparsed.due == "2026-10-25")
check("round-trip content", reparsed.content == "顺序固定", reparsed.content)
check("round-trip tags", vim.deep_equal(reparsed.tags, { "backend", "fix" }), vim.inspect(reparsed.tags))

local start_only_line = format.format_task_line({ id = "aa0006", start = "2026-10-20", content = "x", status = "todo" })
check("start only formatting", start_only_line == "- [ ] todo:aa0006 ~2026-10-20 x", start_only_line)

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
check("format_start spacing", due.format_start("2026-10-20") == " ~2026-10-20", due.format_start("2026-10-20"))
check("format_start nil", due.format_start(nil) == "", due.format_start(nil))
check("extract_start", due.extract_start(" ~2026-10-20 rest") == "2026-10-20")
check("extract_start rejects bad dates", due.extract_start(" ~2026-13-20") == nil)
check("format_span_short interval", due.format_span_short("2026-10-20", "2026-10-25", "2026-10-01") == "10-20→10-25")
check("format_span_short start only", due.format_span_short("2026-10-20", nil, "2026-10-01") == "10-20")
check("format_span_short due only", due.format_span_short(nil, "2026-10-25", "2026-10-01") == "10-25")
check("format_span_short empty", due.format_span_short(nil, nil, "2026-10-01") == "")

---------------------------------------------------------------------
-- 读取期归一化：start 晚于 due 时丢弃 start
---------------------------------------------------------------------
local task = schema.normalize_task({
	core = { content = "x", status = "todo", start = "2026-11-01", due = "2026-10-01" },
}, "aa0007")
check("start after due is dropped", task.core.start == nil, task.core.start)
check("due kept", task.core.due == "2026-10-01", task.core.due)

local good = schema.normalize_task({
	core = { content = "x", status = "todo", start = "2026-10-01", due = "2026-10-05" },
}, "aa0008")
check("valid start kept", good.core.start == "2026-10-01", good.core.start)

local bad_date = schema.normalize_task({ core = { content = "x", start = "2026-02-31" } }, "aa0009")
check("impossible start dropped", bad_date.core.start == nil, bad_date.core.start)

print(string.format("\n%s (%d failed)", fails == 0 and "ALL PASS" or "FAILURES", fails))
os.exit(fails == 0 and 0 or 1)
