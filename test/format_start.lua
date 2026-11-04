-- 行尾元数据块里的 start（`@start(YYYY-MM-DD)`）：解析 / 生成 / 位置回归测试（headless，自包含）。
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
local line = "- [ ] 写点东西 @id(aa0001) @start(2026-10-20) @due(2026-10-25) #fix"
local parsed = format.parse_task_line(line)
check("id parsed", parsed.id == "aa0001", parsed.id)
check("start parsed", parsed.start == "2026-10-20", parsed.start)
check("due parsed after start", parsed.due == "2026-10-25", parsed.due)
check("tags still parsed", #parsed.tags == 1 and parsed.tags[1] == "fix", vim.inspect(parsed.tags))
check("content has no dates", parsed.content == "写点东西", parsed.content)

local only_start = format.parse_task_line("- [ ] 只有开始日 @id(aa0002) @start(2026-10-20)")
check("start only", only_start.start == "2026-10-20" and only_start.due == nil, vim.inspect(only_start))
check("start only content", only_start.content == "只有开始日", only_start.content)

local only_due = format.parse_task_line("- [ ] 只有截止日 @id(aa0003) @due(2026-10-25)")
check("due only", only_due.due == "2026-10-25" and only_due.start == nil)

-- 顺序无关：元数据块从右往左剥，@due 写在 @start 前面也能解析
local reversed = format.parse_task_line("- [ ] 顺序颠倒 @id(aa0004) @due(2026-10-25) @start(2026-10-20)")
check("reversed order parses start", reversed.start == "2026-10-20", vim.inspect(reversed))
check("reversed order parses due", reversed.due == "2026-10-25")
check("reversed order content clean", reversed.content == "顺序颠倒", reversed.content)

-- 未知的 @token 不算元数据，留在正文里
local unknown = format.parse_task_line("- [ ] 正文有 @foo(bar) @id(aa0007)")
check("unknown @token stays in content", unknown.content == "正文有 @foo(bar)", unknown.content)

---------------------------------------------------------------------
-- 生成（幂等：写回去再解析要一样）
---------------------------------------------------------------------
local built = format.format_task_line({
	id = "aa0005",
	start = "2026-10-20",
	due = "2026-10-25",
	tags = { "fix", "backend" },
	content = "顺序固定",
	indent = "",
})
check(
	"generated line puts start before due",
	built == "- [ ] 顺序固定 @id(aa0005) @start(2026-10-20) @due(2026-10-25) #backend #fix",
	built
)
local reparsed = format.parse_task_line(built)
check("round-trip id", reparsed.id == "aa0005")
check("round-trip start/due", reparsed.start == "2026-10-20" and reparsed.due == "2026-10-25")
check("round-trip content", reparsed.content == "顺序固定", reparsed.content)
check("round-trip tags", vim.deep_equal(reparsed.tags, { "backend", "fix" }), vim.inspect(reparsed.tags))

local start_only_line = format.format_task_line({ id = "aa0006", start = "2026-10-20", content = "x" })
check("start only formatting", start_only_line == "- [ ] x @id(aa0006) @start(2026-10-20)", start_only_line)

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 区间不变式：唯一实现 due.align_span（写谁谁让位）
---------------------------------------------------------------------
local s1, d1, a1 = due.align_span("2026-10-20", "2026-10-10", "start")
check("align: start pushes due forward", s1 == "2026-10-20" and d1 == "2026-10-20" and a1 == true, s1 .. " " .. d1)
local s2, d2, a2 = due.align_span("2026-10-20", "2026-10-10", "due")
check("align: due pulls start back", s2 == "2026-10-10" and d2 == "2026-10-10" and a2 == true, s2 .. " " .. d2)
local s3, d3, a3 = due.align_span("2026-10-01", "2026-10-05", "start")
check("align: valid span untouched", s3 == "2026-10-01" and d3 == "2026-10-05" and a3 == false)
local s4, d4, a4 = due.align_span(nil, "2026-10-05", "start")
check("align: no start, nothing to do", s4 == nil and d4 == "2026-10-05" and a4 == false)
local s5, d5, a5 = due.align_span("2026-10-20", nil, "due")
check("align: no due, nothing to do", s5 == "2026-10-20" and d5 == nil and a5 == false)

---------------------------------------------------------------------
-- 光标落点：正文结束处（元数据块之前）
---------------------------------------------------------------------
local L = "- [ ] 记一笔 @id(ab12cd) @created(1730000000) @due(2026-10-05) #fix"
local col = format.content_end_col(L)
check("content_end_col stops before metadata", L:sub(col + 1, col + 1) == " " and L:sub(col + 2, col + 4) == "@id", tostring(col) .. " " .. L:sub(col + 1))
check("content_end_col on plain line is #line", format.content_end_col("just text") == #"just text")
local indented = "    - [d] 深层任务 @id(ab12cd)"
check("content_end_col counts indent and checkbox", format.content_end_col(indented) == #"    - [d] 深层任务", tostring(format.content_end_col(indented)))

print(string.format("\n%s (%d failed)", fails == 0 and "ALL PASS" or "FAILURES", fails))
os.exit(fails == 0 and 0 or 1)
