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
-- 同时把 ~/.todo-files 下按「目录 basename」命名的旧项目目录改名成新的
-- `<slug>--<hash8>`（身份 = git 远端 + 仓库内相对路径，见 utils/project.lua），
-- 这样同名项目不再串、项目搬家也不再散。
--
-- 幂等：已是新格式的行（行尾有合法 `@id(...)`）不会被再次改写；目录已改名则跳过。

local M = {}

-- 脚本随插件分发：把插件自身与 nvim-store3 放进 runtimepath，
-- 这样新格式 / 状态 / 项目身份都复用插件里的同一份实现，不在这里抄一遍。
local script_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(script_root)
local sibling_store = vim.fn.fnamemodify(script_root, ":h") .. "/nvim-store3"
if vim.fn.isdirectory(sibling_store) == 1 then
	vim.opt.runtimepath:prepend(sibling_store)
end

local meta = require("todo2.utils.meta")
local types = require("todo2.store.types")
local tags_utils = require("todo2.utils.tags")
local project = require("todo2.utils.project")

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
-- 新格式识别
---------------------------------------------------------------------
--- 行尾是否已经是新格式（有合法 `@id(...)`）
local function has_new_id(line)
	local rest = line:match("^%s*[-*+]%s+%[[^%]]%]%s*(.*)$")
	return rest ~= nil and meta.parse(rest).id ~= nil
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

	-- `[~start] [@due]`，两者互相独立：只有 due 的承诺是旧格式里最常见的一种
	local date = "%d%d%d%d%-%d%d%-%d%d"
	local start, after_start = after:match("^~(" .. date .. ")%s*(.*)$")
	if start then
		after = after_start
	end
	local due, after_due = after:match("^@(" .. date .. ")%s*(.*)$")
	if due then
		after = after_due
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

	-- 与写入侧同一份归一化，否则首次 sync 会把标签顺序改一遍
	local normalized = tags_utils.normalize(tags)

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
-- 旧行 → 新 checkbox（状态定义统一来自 store/types）
---------------------------------------------------------------------
--- 旧前缀 > 旧 checkbox > 默认活跃状态
local function checkbox_of(default_status, old)
	local status = old.status
	if not (status and types.is_known(status)) then
		status = types.checkbox_to_status((old.checkbox or ""):lower()) or default_status
	end
	return types.status_to_checkbox(status):sub(2, -2)
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
			-- nvim-store3 的布局：{ data = { ["facts.tasks.<id>"] = task, ... } }
			local buckets = ok and data and data.data
			if type(buckets) == "table" then
				for key, task in pairs(buckets) do
					local id = key:match("^facts%.tasks%.(.+)$")
					if id and type(task) == "table" then
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
	end
	return map, scanned
end

---------------------------------------------------------------------
-- 项目目录改名：旧名 = 目录 basename → 新名 = <slug>--<hash8>
---------------------------------------------------------------------
---@return { renamed: number, ambiguous: table, conflicts: table, unknown: table[] }
local function migrate_project_dirs(opts)
	local report = { renamed = 0, ambiguous = {}, conflicts = {}, unknown = {} }
	if vim.fn.isdirectory(opts.store) == 0 then
		return report
	end

	-- 以 store 的 meta.root 为准：根还在，才知道这个目录属于哪个项目
	local by_old, known_names = {}, {}
	for name in vim.fs.dir(opts.store) do
		local ok, data = pcall(function()
			return vim.json.decode(table.concat(vim.fn.readfile(opts.store .. "/" .. name .. "/meta.json"), "\n"))
		end)
		local root = ok and type(data) == "table" and data.root
		if type(root) == "string" and vim.fn.isdirectory(root) == 1 then
			local old_name = project.basename(root)
			local new_name = project.get_project_name(root)
			known_names[new_name] = true
			by_old[old_name] = by_old[old_name] or {}
			table.insert(by_old[old_name], { root = root, new = new_name })
		end
	end

	for old_name, list in pairs(by_old) do
		local old_dir = opts.vault .. "/" .. old_name
		local new_name = list[1].new
		local new_dir = opts.vault .. "/" .. new_name
		-- 目录名来自项目根的 basename，根是 "/" 时会得到空串或 "/"：绝不能拿它去 rename
		if old_name:find("[/\\]") or old_name == "" or old_name == "." or old_name == ".." then
			table.insert(report.unknown, old_name == "" and "/" or old_name)
		elseif old_name ~= new_name and vim.fn.isdirectory(old_dir) == 1 then
			if #list > 1 then
				-- 同名目录曾经被多个项目共用：谁的东西分不清，交给人处理
				table.insert(report.ambiguous, old_name .. " ← " .. vim.tbl_count(list) .. " projects")
			elseif vim.fn.isdirectory(new_dir) == 1 then
				table.insert(report.conflicts, old_dir .. " → " .. new_dir)
			elseif opts.apply then
				vim.fn.rename(old_dir, new_dir)
				report.renamed = report.renamed + 1
				print(string.format("renamed  %s → %s", old_name, new_name))
			else
				report.renamed = report.renamed + 1
				print(string.format("would rename  %s → %s", old_name, new_name))
			end
		end
	end

	-- 给能认出来的目录补上清单（含已经改好名的）
	if opts.apply then
		for _, list in pairs(by_old) do
			for _, item in ipairs(list) do
				local dir = opts.vault .. "/" .. item.new
				if vim.fn.isdirectory(dir) == 1 then
					project.write_manifest({
						name = item.new,
						label = project.basename(item.root),
						dir = dir,
						root = item.root,
						identity = project.get_identity(item.root),
					})
				end
			end
		end
	end

	for name in vim.fs.dir(opts.vault) do
		if name:sub(1, 1) ~= "." and not known_names[name] and vim.fn.isdirectory(opts.vault .. "/" .. name) == 1 then
			local known = false
			for _, list in pairs(by_old) do
				for _, item in ipairs(list) do
					if item.new == name or project.basename(item.root) == name then
						known = true
					end
				end
			end
			if not known then
				table.insert(report.unknown, name)
			end
		end
	end
	return report
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
			local cb = checkbox_of(ctx.default_status, old)
			local ts = ctx.timestamps[old.id] or {}
			local new_line = string.format("%s%s [%s] ", old.indent, old.bullet, cb)
				.. old.content
				.. meta.format({
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

	-- types.setup 收的是配置项（label/checkbox/type），命令行只是状态名
	local cycle_defs = {}
	for i, label in ipairs(opts.cycle) do
		cycle_defs[i] = { label = label }
	end
	types.setup(cycle_defs)
	local dirs = migrate_project_dirs(opts)
	local timestamps, store_dirs = load_timestamps(opts.store)
	local files = collect_files(opts.vault)

	local ctx = {
		apply = opts.apply,
		vault = opts.vault,
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

	print(string.format("project dirs: renamed=%d", dirs.renamed))
	for _, item in ipairs(dirs.ambiguous) do
		print("  ambiguous (同名目录被多个项目共用，请手工处理): " .. item)
	end
	for _, item in ipairs(dirs.conflicts) do
		print("  conflict (目标目录已存在，跳过): " .. item)
	end
	if #dirs.unknown > 0 then
		print("  unknown (没有 store 记录，保持原名): " .. table.concat(dirs.unknown, ", "))
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
