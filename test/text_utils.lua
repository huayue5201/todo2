-- utils/text.lua（显示宽度统一入口）+ 进度条单一来源的回归测试（headless 自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-text-xdg nvim --headless -u NONE -l test/text_utils.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

-- 在临时目录里跑：避免在仓库里生成 .todo2/ 项目配置
local projdir = "/tmp/todo2-text-utils-proj"
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)

require("todo2").setup({})

local text = require("todo2.utils.text")
local progress = require("todo2.render.progress")
local statistics = require("todo2.ui.statistics")
local config = require("todo2.config")

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
-- 宽度一律按显示列
---------------------------------------------------------------------
check("width counts cells not bytes", text.width("中文abc") == 7, text.width("中文abc"))
check("width of nil is 0", text.width(nil) == 0)
check("width of empty string is 0", text.width("") == 0)

check("pad_end pads to width", text.pad_end("中文", 6) == "中文  ", "[" .. text.pad_end("中文", 6) .. "]")
check("pad_end leaves wider text alone", text.pad_end("abcdef", 3) == "abcdef")
check("center splits the padding", text.center("ab", 6) == "  ab")
check("center never overflows", text.width(text.center("中文", 5)) <= 5, text.center("中文", 5))

check("truncate keeps short text", text.truncate("abc", 5) == "abc")
check("truncate adds an ellipsis", text.truncate("abcdefgh", 5) == "abcd…", text.truncate("abcdefgh", 5))
check("truncate counts CJK as 2 cells", text.truncate("中文字符测试", 5) == "中文…", text.truncate("中文字符测试", 5))
check("truncate result never exceeds width", text.width(text.truncate("中文字符测试", 4)) <= 4)

check("max_width over lines", text.max_width({ "中", "abcd" }) == 4)

---------------------------------------------------------------------
-- 进度条只有一个来源：render/progress（字符/长度/style 跟配置）
---------------------------------------------------------------------
local chars = config.get("progress_bar.chars")
local bar = progress.bar_text({ percent = 40, total = 5 })
check("bar uses configured chars", bar:find(chars.filled, 1, true) ~= nil and bar:find(chars.empty, 1, true) ~= nil, bar)
check("bar length stays within config bounds", text.width(bar) == 5, text.width(bar))

config.set("progress_bar.chars.filled", "#")
config.set("progress_bar.chars.empty", ".")
check("bar follows a config change", progress.bar_text({ percent = 40, total = 5 }) == "##...", progress.bar_text({ percent = 40, total = 5 }))

-- 统计摘要必须用同一套字符（曾经自带 █/░ 且忽略 style）
local summary = statistics.format_summary({ total_items = 5, completed_items = 2, total_tasks = 3, done = 1 })
check("statistics uses the same bar chars", summary:find("##...", 1, true) ~= nil, summary)
check("statistics keeps the counts", summary:find("total: 2/5", 1, true) ~= nil, summary)

config.set("progress_bar.style", "percent")
check("style=percent drops the bar", progress.bar_text({ percent = 40, total = 5 }) == "")
check("statistics still renders a percent", statistics.format_summary({ total_items = 5, completed_items = 2 }):find("40%%") ~= nil)

print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
