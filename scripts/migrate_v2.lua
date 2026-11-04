-- 一次性迁移：旧行格式 → 新行格式（todo2 v2）
--
-- 旧：- [ ] todo:ab12cd ~2026-06-20 @2026-07-01 #fix 内容
-- 新：- [ ] 内容 @id(ab12cd) @created(1730000000) @start(2026-06-20) @due(2026-07-01) #fix
--
-- 旧文件把状态写在 `<status>:<id>` 前缀里、时间戳只存在 store，所以本脚本
-- 自己解析旧语法，并从 store 的 data.json 里把 created/completed/archived
-- 回填到行尾（store 找不到时留空，不做猜测）。
--
-- 用法：
--   nvim --headless -u NONE -l scripts/migrate_v2.lua            # 只报告（dry-run）
--   nvim --headless -u NONE -l scripts/migrate_v2.lua --apply    # 备份后写回
--
-- 选项：
--   --apply               真正写文件（默认只打印将要做的改动）
--   --vault=<dir>         TODO 文件目录（默认 ~/.todo-files）
--   --store=<dir>         store 的 projects 目录（默认 $XDG_DATA_HOME/nvim/nvim-store/projects）
--   --cycle=a,b,c         活跃状态的循环顺序（默认 todo,doing,blocked）
--
-- 幂等：已是新格式的行（行尾有合法 `@id(...)`）不会被再次改写。

local M = {}

---------------------------------------------------------------------
-- 参数
---------------------------------------------------------------------
local function parse_args(argv)
	local opts = {
		apply = false,
		vault = vim.fn.expand("~/.todo-files"),
		store = vim.fn.stdpath("data") .. "/nvim-store/projects",
		cycle = { "todo", "doing", "blocked" },
	}
	for _, a in ipairs(argv or {}) do
		if a == "--apply" then
			opts.apply = true
		elseif a:match("^%-%-vault=") then
			opts.vault = vim.fn.expand(a:sub(9))
		elseif a:match("^%-%-store=") then
			opts.store = vim.fn.expand(a:sub(9))
		elseif a:match("^%-%-cycle=") then
			opts.cycle = vim.split(a:sub(9), ",", { trimempty = true })
		elseif a == "--help" or a == "-h" then
			opts.help = true
		else
			error("unknown argument: " .. a)
		end
	end
	return opts
end

---------------------------------------------------------------------
-- 新格式的元数据块（与 lua/todo2/utils/meta.lua 同序同语法）
---------------------------------------------------------------------
local ORDER = { "id", "created", "start", "due", "done", "archived" }

local function is_date(v)
	return v:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

local VALID = {
	id = function(v)
		return v:match("^[0-9a-z]+$") ~= nil
	end,
	created = function(v)
		return v:match("^%d+$") ~= nil
	end,
	done = function(v)
		return v:match("^%d+$") ~= nil
	end,
	archived = function(v)
		return v:match("^%d+$") ~= nil
	end,
	start = is_date,
	due = is_date,
}

local function format_meta(fields)
	local out = {}
	for _, key in ipairs(ORDER) do
		local v = fields[key]
		if v ~= nil and v ~= "" and VALID[key](tostring(v)) then
			out[#out + 1] = "@" .. key .. "(" .. tostring(v) .. ")"
		end
	end
	if fields.tags and #fields.tags > 0 then
		out[#out + 1] = "#" .. table.concat(fields.tags, " #")
	end
	if #out == 0 then
		return ""
	end
	return " " .. table.concat(out, " ")
end

--- 行尾是否已有新格式的 `@id(...)`
local function has_new_id(line)
	return line:find("@id%(([0-9a-z]+)%)") ~= nil
end

---------------------------------------------------------------------
-- 旧格式解析
---------------------------------------------------------------------
---@return table|nil  {indent, bullet, checkbox, status, id, start, due, tags, content}
local function parse_old(line)
	local indent, bullet, cb, rest = line:match("^(%s*)([-*+])%s+%[([^%]])%]%s*(.*)$")
	if not indent then
		return nil
	end
	if has_new_id(line) then
		return nil
	end

	-- `<status>:<id>` 前缀（旧格式的唯一 ID 载体）
	local status, id, after = rest:match("^([%w][%w_%-]*):([0-9a-z]+)%s+(.*)$")
	if not id then
		-- 没有 id 的普通任务：内容原样保留，只补行尾元数据（无）
		return { indent = indent, bullet = bullet, checkbox = cb, content = rest }
	end

	local start, after_start = after:match("^~(%d%d%d%d%-%d%d%-%d%d)%s*(.*)$")
	local due, after_due
	if start then
		after = after_start
		due, after_due = after:match("^@(%d%d%d%d%-%d%d%-%d%d)%s*(.*)$")
		if due then
			after = after_due
		end
	end
	local tags = {}
	while true do
		local tag, remainder = after:match("^#([%w_%-/]+)%s+(.*)$")
		if not tag then
			break
		end
		tags[#tags + 1] = tag:lower()
		after = remainder
	end

	-- 与 lua/todo2/utils/tags.lua 的 normalize 一致：小写、去重、排序，
	-- 否则首次 sync 会把标签顺序改一遍
	local seen, normalized = {}, {}
	for _, tag in ipairs(tags) do
		if not seen[tag] then
			seen[tag] = true
			normalized[#normalized + 1] = tag
		end
	end
	table.sort(normalized)

	return {
		indent = indent,
		bullet = bullet,
		checkbox = cb,
		status = status,
		id = id,
		start = start,
		due = due,
		tags = normalized,
		content = after,
	}
end

---------------------------------------------------------------------
-- 状态 → 新 checkbox（与 lua/todo2/store/types.lua 同一规则）
---------------------------------------------------------------------
local function build_checkbox_map(cycle)
	local used = { [" "] = true, x = true, X = true, [">"] = true }
	local by_status = {
		completed = "x",
		archived = ">",
	}
	for i, label in ipairs(cycle) do
		local cb = " "
		if i > 1 then
			cb = nil
			for ch in label:lower():gmatch("%w") do
				if not used[ch] then
					cb = ch
					break
				end
			end
			if not cb then
				error(string.format("no free checkbox char for status %q; pass --cycle with shorter labels", label))
			end
		end
		used[cb] = true
		by_status[label] = cb
	end
	return by_status
end

local function checkbox_of(by_status, default_status, old)
	if old.status and by_status[old.status] then
		return by_status[old.status]
	end
	if old.checkbox == "x" or old.checkbox == "X" then
		return by_status.completed
	end
	if old.checkbox == ">" then
		return by_status.archived
	end
	-- 旧文件里 `[ ]` 可能是任意活跃状态，但状态已随前缀迁移；无前缀则用默认态
	return by_status[default_status]
end

---------------------------------------------------------------------
-- store 里的时间戳（id → {created, completed, archived}）
---------------------------------------------------------------------
local function load_timestamps(store_dir)
	local map = {}
	if vim.fn.isdirectory(store_dir) == 0 then
		return map, 0
	end
	local scanned = 0
	for name in vim.fs.dir(store_dir) do
		local path = store_dir .. "/" .. name .. "/data.json"
		if vim.fn.filereadable(path) == 1 then
			scanned = scanned + 1
			local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
			local tasks = ok and data and data.tasks
			if type(tasks) == "table" then
				for id, task in pairs(tasks) do
					local ts = task.timestamps or {}
					map[id] = {
						created = ts.created,
						completed = ts.completed,
						archived = ts.archived,
					}
				end
			end
		end
	end
	return map, scanned
end

---------------------------------------------------------------------
-- 收集文件
---------------------------------------------------------------------
local function collect_files(dir)
	local files = {}
	local function walk(path)
		for name, kind in vim.fs.dir(path) do
			local full = path .. "/" .. name
			if kind == "directory" then
				if not name:match("^%.") then
					walk(full)
				end
			elseif name == "todo.txt" or name:match("%.todo%.md$") or name:match("%.todo$") or name:match("%.todo%.txt$") then
				files[#files + 1] = full
			end
		end
	end
	walk(dir)
	table.sort(files)
	return files
end

---------------------------------------------------------------------
-- 迁移一个文件
---------------------------------------------------------------------
local function migrate_file(path, ctx)
	local original = vim.fn.readfile(path)
	local lines = vim.deepcopy(original)
	local changed = {}
	for i, line in ipairs(lines) do
		local old = parse_old(line)
		if old and old.id then
			local cb = checkbox_of(ctx.by_status, ctx.default_status, old)
			local ts = ctx.timestamps[old.id] or {}
			local new_line = string.format("%s%s [%s] ", old.indent, old.bullet, cb)
				.. old.content
				.. format_meta({
					id = old.id,
					created = ts.created,
					start = old.start,
					due = old.due,
					done = (cb == "x") and ts.completed or nil,
					archived = (cb == ">") and ts.archived or nil,
					tags = old.tags,
				})
			if new_line ~= line then
				lines[i] = new_line
				changed[#changed + 1] = { lnum = i, before = line, after = new_line }
				if ts.created == nil then
					ctx.missing_created = ctx.missing_created + 1
				end
			end
		elseif old and not old.id then
			ctx.plain_tasks = ctx.plain_tasks + 1
		end
	end

	if #changed == 0 then
		return 0, {}
	end

	if ctx.apply then
		local backup = ctx.backup_root .. path:sub(#ctx.vault + 1)
		vim.fn.mkdir(vim.fn.fnamemodify(backup, ":h"), "p")
		vim.fn.writefile(original, backup)
		vim.fn.writefile(lines, path)
	end
	return #changed, changed
end

---------------------------------------------------------------------
-- 入口
---------------------------------------------------------------------
function M.main(argv)
	local opts = parse_args(argv)
	if opts.help then
		print([[
usage: nvim --headless -u NONE -l scripts/migrate_v2.lua [--apply]
           [--vault=DIR] [--store=DIR] [--cycle=todo,doing,blocked]])
		return 0
	end

	if vim.fn.isdirectory(opts.vault) == 0 then
		print("vault not found: " .. opts.vault)
		return 1
	end

	local by_status = build_checkbox_map(opts.cycle)
	local timestamps, store_dirs = load_timestamps(opts.store)
	local files = collect_files(opts.vault)

	local ctx = {
		apply = opts.apply,
		vault = opts.vault,
		by_status = by_status,
		default_status = opts.cycle[1],
		timestamps = timestamps,
		backup_root = opts.vault .. "/.migrate-backup",
		missing_created = 0,
		plain_tasks = 0,
	}

	print(string.format("%s  vault=%s  store=%s (%d project dirs, %d ids)",
		opts.apply and "APPLY" or "DRY-RUN", opts.vault, opts.store, store_dirs, vim.tbl_count(timestamps)))

	local total_lines, changed_files, samples = 0, 0, {}
	for _, path in ipairs(files) do
		local n, changed = migrate_file(path, ctx)
		if n > 0 then
			changed_files = changed_files + 1
			total_lines = total_lines + n
			for _, c in ipairs(changed) do
				if #samples < 5 then
					samples[#samples + 1] = string.format("%s:%d\n  - %s\n  + %s", path, c.lnum, c.before, c.after)
				end
			end
		end
	end

	print(string.format("files=%d  changed files=%d  changed lines=%d  plain tasks kept=%d",
		#files, changed_files, total_lines, ctx.plain_tasks))
	if ctx.missing_created > 0 then
		print(string.format("note: %d tasks had no created timestamp in the store (left empty)", ctx.missing_created))
	end
	for _, s in ipairs(samples) do
		print("\n" .. s)
	end
	if not opts.apply and total_lines > 0 then
		print("\nre-run with --apply to write (a backup of every touched file is kept in "
			.. ctx.backup_root .. ")")
	end
	return 0
end

local argv = _G.arg or {}
local ok, err = pcall(M.main, argv)
if not ok then
	print("migrate failed: " .. tostring(err))
	os.exit(1)
end
