-- 代码锚点「列」契约测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/anchor_col.lua
--
-- 覆盖：capture/refine 纯函数 / create_task 带 col / 越界校验 /
--       extmark 在行内插入后自动跟随列 / link_code 带 col。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-anchor-col-test"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir .. "/src", "p")
vim.fn.chdir(projdir)

require("todo2").setup({})
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-anchor-col-test"), "rf")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local anchor_utils = require("todo2.utils.anchor")
local anchors = require("todo2.ai.anchors")
local core = require("todo2.store.task.core")
local ai = require("todo2.ai")
local actions = require("todo2.ai.actions")

---------------------------------------------------------------------
-- 纯函数
---------------------------------------------------------------------
local text = "local foo = bar.baz + qux"
local baz_start = text:find("baz", 1, true) - 1

local c, e, s = anchor_utils.capture(text, baz_start + 1)
check("capture starts at token boundary", c == baz_start and e == baz_start + 3, ("%s..%s"):format(tostring(c), tostring(e)))
check("capture snippet", s == "baz", tostring(s))

local c2, e2, s2 = anchor_utils.capture(text, 0)
check("capture on keyword at col 0", c2 == 0 and e2 == 5 and s2 == "local", tostring(s2))

local c3, e3, s3 = anchor_utils.capture(text, text:find(" ", 1, true) - 1)
check("capture on whitespace keeps col", c3 == 5 and e3 == 5 and s3 == nil, tostring(c3))

local clamped = anchor_utils.clamp(text, 9999)
check("clamp high", clamped == #text, clamped)
check("clamp low", anchor_utils.clamp(text, -3) == 0)

local moved = "local longer_prefix = bar.baz + qux"
local rc, re = anchor_utils.refine(moved, baz_start, baz_start + 3, "baz")
check(
	"refine follows snippet",
	rc == moved:find("baz", 1, true) - 1 and re == rc + 3,
	("%s..%s"):format(tostring(rc), tostring(re))
)
local fallback_text = "nothing here"
local missing_c, missing_e = anchor_utils.refine(fallback_text, baz_start, baz_start + 3, "baz")
check("refine falls back to clamped col", missing_c == #fallback_text and missing_e == #fallback_text)

---------------------------------------------------------------------
-- create_task + col
---------------------------------------------------------------------
local code = projdir .. "/src/main.rs"
vim.fn.writefile({
	"fn main() {",
	"    let target = compute(alpha, beta);",
	"}",
}, code)

actions.create_todo_file("test")

local beta_start = ("    let target = compute(alpha, beta);"):find("beta", 1, true) - 1
local r, err = anchors.create_task({
	content = "beta target",
	anchor = { path = code, line = 2, col = beta_start + 2 },
})
check("create_task with col", r and r.ok == true, err)
local loc = r and core.get_task(r.id).locations.code
check("col normalized to token start", loc and loc.col == beta_start, loc and loc.col)
check("end_col covers token", loc and loc.end_col == beta_start + 4, loc and loc.end_col)
check("snippet saved", loc and loc.snippet == "beta", loc and loc.snippet)
check("build exposes col", r and ai.build(r.id).anchor.col == beta_start, r and ai.build(r.id).anchor.col)

local r2, err2 = anchors.create_task({
	content = "bad col",
	anchor = { path = code, line = 2, col = 999 },
})
check("out-of-range col rejected", r2 == nil and type(err2) == "string" and err2:find("col", 1, true) ~= nil, err2)

local r3, err3 = anchors.create_task({
	content = "no col",
	anchor = { path = code, line = 3 },
})
check("col remains optional", r3 and r3.ok == true and r3.anchor.col == nil, err3)

---------------------------------------------------------------------
-- extmark 跟踪：在锚点之前插入文本，列应自动右移
---------------------------------------------------------------------
vim.cmd("edit " .. vim.fn.fnameescape(code))
local bufnr = vim.api.nvim_get_current_buf()
-- 等 BufReadPost 的 deferred attach 完成，否则 on_lines 还没注册。
vim.wait(300, function()
	return false
end)
vim.wait(500, function()
	return vim.api.nvim_buf_is_loaded(bufnr) and #require("todo2.store.index").find_code_links_by_file(code) > 0
end)

local before = core.get_task(r.id).locations.code.col
local prefix = "PREFIX "
vim.api.nvim_buf_set_text(bufnr, 1, 0, 1, 0, { prefix })
local expected = before + #prefix
local followed = vim.wait(2000, function()
	local l = core.get_task(r.id).locations.code
	return l and l.col == expected
end, 20)
local after = core.get_task(r.id).locations.code.col
check("extmark follows inline insert", followed, ("%s -> %s, expected %d"):format(tostring(before), tostring(after), expected))

---------------------------------------------------------------------
-- link_code 带 col
---------------------------------------------------------------------
local todo_file = actions.create_todo_file("t")
local act = actions.create_task({ content = "manual link", path = todo_file.path })
local lr, lerr = anchors.link_code(act.id, code, 3, 0)
check("link_code with col", lr and lr.ok == true, lerr)
check("link_code stores col", core.get_task(act.id).locations.code.col == 0)

local lr2, lerr2 = anchors.link_code(act.id, code, 3, 999)
check("link_code rejects bad col", lr2 == nil and type(lerr2) == "string" and lerr2:find("col", 1, true) ~= nil, lerr2)

if fails > 0 then
	print(("FAILED: %d"):format(fails))
	vim.cmd("cq")
end
print("ALL PASS")
