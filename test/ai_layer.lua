-- AI 交接层契约测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/ai_layer.lua
--
-- 覆盖：create_note（无锚点）/ 幂等去重 / 子任务 / list / search / 分页 /
--       update_content / project_info / build（含归档可见性）/ archive / unarchive / delete。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-ai-test-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)

require("todo2").setup({})
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-ai-test-proj"), "rf")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local actions = require("todo2.ai.actions")
local ai = require("todo2.ai")
local store_archive = require("todo2.store.archive")

local f = actions.create_todo_file("test")
check("create_todo_file", f and f.path ~= nil, f and f.path)
local a = actions.create_task({ content = "hello alpha" })
check("create_note anchorless", a and a.id ~= nil, a and a.id)
local aid = a and a.id

local a2 = actions.create_task({ content = "hello alpha" })
check("dedup", a2 and a2.deduped == true and a2.id == aid, a2 and tostring(a2.deduped))

local c = actions.create_task({ content = "child gamma", parent_id = aid })
check("child", c and c.id ~= nil, c and c.id)

local list = ai.list({})
local found_a = false
for _, it in ipairs(list) do
	if it.id == aid then
		found_a = true
	end
end
check("list contains A", #list >= 2 and found_a, #list)

local sr = ai.search({ query = "alpha" })
check("search alpha", #sr >= 1 and sr[1].content == "hello alpha", #sr)
check("search gamma", #ai.search({ query = "gamma" }) >= 1)

local p0 = ai.list({ limit = 1, offset = 0 })
local p1 = ai.list({ limit = 1, offset = 1 })
check("paginate limit1", #p0 == 1, #p0)
check("paginate distinct", #p1 == 1 and p1[1].id ~= p0[1].id, #p1)

local uc = actions.update_content(aid, "hello beta")
check("update_content", uc and uc.content == "hello beta", uc and uc.content)
check("search updated", #ai.search({ query = "hello beta" }) >= 1)

local pi = ai.project_info()
check("project_info", pi and pi.project == "todo2-ai-test-proj" and pi.active_tasks >= 2, pi and pi.active_tasks)

local b = ai.build(aid)
check("build active", b and b.archived == nil, b and tostring(b.archived))

local ar = actions.archive_task(c.id)
check("archive child", ar and ar.archived == true, ar and ar.total)
check("archive tombstone", store_archive.is_archived(c.id) == true)
check("archive removed from list", (function()
	for _, it in ipairs(ai.list({})) do
		if it.id == c.id then
			return false
		end
	end
	return true
end)())

local seen_arch = false
for _, it in ipairs(ai.list({ include_archived = true })) do
	if it.id == c.id then
		seen_arch = it.archived == true
	end
end
check("list include_archived", seen_arch)
local ba = ai.build(c.id)
check("build archived", ba and ba.archived == true, ba and tostring(ba.archived))
local sa = ai.search({ query = "gamma" })
check("search archived", #sa >= 1 and sa[1].archived == true, #sa)
local has_arch_group = false
for _, gr in ipairs(ai.tree({ include_archived = true }).files) do
	if gr.archived then
		has_arch_group = true
	end
end
check("tree archived group", has_arch_group)

local ur = actions.unarchive_task(c.id)
check("unarchive", ur and ur.unarchived == true, ur and ur.total)
check("unarchive tombstone cleared", store_archive.is_archived(c.id) ~= true)

local d = actions.delete_task(c.id)
check("delete child", d and d.deleted == true, d and d.deleted)
check("delete gone", require("todo2.store.task.core").get_task(c.id) == nil)

actions.archive_task(c.id)
local dz = select(2, actions.delete_task(c.id))
check("delete archived refuses", dz ~= nil and tostring(dz):find("archived") ~= nil, dz)
actions.unarchive_task(c.id)

check("build json-encodable", pcall(vim.json.encode, b))
check("to_markdown", pcall(ai.to_markdown, b))

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
vim.cmd("qa!")
