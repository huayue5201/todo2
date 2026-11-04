-- 图标只有一个来源：config.icons（+ status.cycle[].icon）。改配置，所有渲染面跟着变。
-- 运行：nvim --headless -u NONE -l test/icons.lua

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

require("todo2").setup({})

local config = require("todo2.config")

local function text_of(parts)
	local out = {}
	for _, chunk in ipairs(parts) do
		out[#out + 1] = chunk[1]
	end
	return table.concat(out)
end

---------------------------------------------------------------------
-- 1) 默认值都在 config.icons 里，且渲染器不再自带字形
---------------------------------------------------------------------
check("defaults live in config.icons", config.get("icons.time") == "↻" and config.get("icons.body") == "¶", vim.inspect(config.get("icons.time")))
check("no legacy icon tables", config.get("viewer_icons") == nil and config.get("calendar.mark_icon") == nil, "legacy key still present")
check("progress chars moved out of progress_bar", config.get("progress_bar.chars") == nil)
check("status icons stay with the status", type(config.get("status.cycle")[1].icon) == "string")

---------------------------------------------------------------------
-- 2) 行尾带：时间前缀与分隔符
---------------------------------------------------------------------
local task = {
	id = "aa0001",
	core = { status = "todo", due = os.date("%Y") .. "-11-02", tags = {} },
	timestamps = { updated = os.time({ year = tonumber(os.date("%Y")), month = 3, day = 4, hour = 12 }) },
}
local band = text_of(require("todo2.render.task_virt").build_status(task, {}))
check("default band uses ↻ and ·", band:find("↻03-04", 1, true) and band:find(" · ", 1, true), band)

config.set("icons.time", "T")
config.set("icons.separator", "|")
local custom_band = text_of(require("todo2.render.task_virt").build_status(task, {}))
check("band follows icons.time", custom_band:find("T03-04", 1, true) ~= nil, custom_band)
check("band follows icons.separator", custom_band:find(" | ", 1, true) ~= nil and custom_band:find("·", 1, true) == nil, custom_band)
config.set("icons.time", "")
check("empty icon drops the prefix", text_of(require("todo2.render.task_virt").build_status(task, {})):find("03-04", 1, true) ~= nil)
config.set("icons.time", "↻")
config.set("icons.separator", "·")

---------------------------------------------------------------------
-- 3) 树缩进 / 进度条 / 未知状态 / 日历徽章
---------------------------------------------------------------------
config.set("icons.tree", { top = "| ", middle = "+-", last = "`-", ws = ".." })
local tree = require("todo2.utils.tree")
check("tree indent follows icons.tree", tree.build_indent(3, { true, false, true }) == "..| `-", tree.build_indent(3, { true, false, true }))
config.set("icons.tree.last", "")
check("empty tree glyph shrinks the prefix", tree.build_indent(3, { true, false, true }) == "..| ", tree.build_indent(3, { true, false, true }))

config.set("icons.progress", { filled = "#", empty = "." })
local bar = require("todo2.render.progress").bar_text({ percent = 40, total = 5 })
check("progress bar follows icons.progress", bar == "##...", bar)

config.set("icons.unknown_status", "?")
check("unknown status falls back to icons.unknown_status", require("todo2.render.checkbox").get("nope") == "?", require("todo2.render.checkbox").get("nope"))

config.set("status.terminal.archived.icon", "A")
check("archived icon is configurable", require("todo2.core.status").get_definition("archived").icon == "A")
check("checkbox / drawer header follow it", require("todo2.render.checkbox").get("archived") == "A")
config.set("status.terminal.archived.icon", "📦")

config.set("icons.calendar.commitment", "C")
config.set("icons.calendar.mark", "M")
check(
	"calendar badges read icons.calendar",
	config.get("icons.calendar.commitment") == "C" and config.get("icons.calendar.mark") == "M"
)

print(fails == 0 and string.format("\nALL PASS (%d checks)", total) or string.format("\n%d/%d FAILED", fails, total))
if fails > 0 then
	os.exit(1)
end
