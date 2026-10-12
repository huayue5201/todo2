-- epoch 护栏测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-epoch-xdg nvim --headless -u NONE -l test/epoch_guard.lua
--
-- 覆盖：单实例正常写入并推进 epoch；并发第二实例可正常写入；
--       陈旧实例在他人写入后被拒绝整库覆盖（生成冲突快照、磁盘不变）；
--       新会话重新加载后恢复可写。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local JsonBackend = require("nvim-store3.storage.json_backend")

local path = "/tmp/todo2-epoch-guard-test/data.json"
vim.fn.delete("/tmp/todo2-epoch-guard-test", "rf")
vim.fn.mkdir("/tmp/todo2-epoch-guard-test", "p")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local function new_backend()
	return JsonBackend.new({ path = path, version = 2, epoch_guard = true, flush_delay = 0 })
end

local function read_file()
	local raw = vim.fn.readfile(path)
	if #raw == 0 then
		return nil
	end
	return vim.json.decode(table.concat(raw, "\n"))
end

local function conflict_files()
	return vim.fn.glob(path .. ".conflict*", false, true)
end

-- 1. 单实例：首次写入 → epoch {n=1}
local A = new_backend()
A:set("todo.task.a", { content = "A1" })
A:flush()
local f = read_file()
check("首写落盘 version=2", f and f.version == 2)
check("首写 epoch.n=1", f and f.epoch and f.epoch.n == 1, f and f.epoch and f.epoch.n)
check("首写数据存在", f and f.data["todo.task.a"] and f.data["todo.task.a"].content == "A1")

-- 2. 同一实例再次写入 → epoch 递增
A:set("todo.task.a", { content = "A2" })
A:flush()
f = read_file()
check("同实例续写 epoch.n=2", f.epoch.n == 2, f.epoch.n)

-- 3. 第二实例（并发）加载后可正常写入
local B = new_backend()
check("B 加载", B:get("todo.task.a") ~= nil)
B:set("todo.task.b", { content = "B1" })
B:flush()
f = read_file()
check("B 写入成功", f.data["todo.task.b"] ~= nil)
check("B 写入后 epoch.n=3", f.epoch.n == 3, f.epoch.n)

-- 4. 陈旧实例 A（其 seen 仍为 {n=2}）再写 → 被拒绝，磁盘不变
local before = read_file()
A:set("todo.task.a", { content = "A-STALE" })
local ok = A:flush()
local after = read_file()
check("陈旧写入被拒绝(flush=false)", ok == false)
check("陈旧写入未污染磁盘", after.data["todo.task.a"].content == "A2", after.data["todo.task.a"].content)
check("磁盘 epoch 未被推进", after.epoch.n == before.epoch.n and after.epoch.writer == before.epoch.writer)
check("已标记冲突", A._conflict == true)
local cf = conflict_files()
check("生成了冲突快照(>=2)", #cf >= 2, #cf)

-- 冲突后重复写入不应反复处理/报错
A:set("todo.task.a", { content = "A-STALE2" })
check("冲突后 flush 仍被拒绝", A:flush() == false)

-- 5. 新会话加载 → 采纳磁盘 epoch，可继续写
local C = new_backend()
check("C 加载", C:get("todo.task.b") ~= nil)
C:set("todo.task.c", { content = "C1" })
C:flush()
f = read_file()
check("新会话写入成功", f.data["todo.task.c"] ~= nil)
check("新会话 epoch.n=4", f.epoch.n == 4, f.epoch.n)

-- 6. 关闭护栏时行为不变（仍整库写入，不受陈旧限制）
local path2 = "/tmp/todo2-epoch-guard-test/data-noguard.json"
local G = JsonBackend.new({ path = path2, version = 2, flush_delay = 0 })
G:set("x", 1)
G:flush()
local g = vim.json.decode(table.concat(vim.fn.readfile(path2), "\n"))
check("无护栏仍正常写入", g.data.x == 1)
check("无护栏不写 epoch", g.epoch == nil)

print(string.rep("-", 40))
if fails == 0 then
	print("ALL PASS")
else
	print("FAILS = " .. fails)
end
vim.cmd("qa!")
