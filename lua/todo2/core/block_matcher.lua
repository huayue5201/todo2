-- lua/todo2/core/block_matcher.lua
-- 轻量 AST：结构 diff + 移动检测（带置信度评分）
---@module "todo2.core.block_matcher"

local M = {}

local signature = require("todo2.core.block_signature").signature

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------

---将 AST 展平为列表（保留结构信息）
---@param node table AST节点
---@param list table? 结果列表
---@return table[] 展平后的节点列表
local function flatten_ast(node, list)
	list = list or {}
	table.insert(list, node)
	for _, child in ipairs(node.children or {}) do
		flatten_ast(child, list)
	end
	return list
end

---为 AST 列表生成签名表
---@param list table[] AST节点列表
---@return table[] 签名表，每个元素包含 node 和 sig
local function build_signature_map(list)
	local map = {}
	for _, node in ipairs(list) do
		local sig = signature(node)
		table.insert(map, {
			node = node,
			sig = sig,
		})
	end
	return map
end

---计算两个节点的匹配分数
---@param old_sig table 旧节点签名
---@param new_sig table 新节点签名
---@return number 匹配分数（越高表示越匹配）
local function calculate_match_score(old_sig, new_sig)
	local score = 0

	-- 1. 类型相同：基础分
	if old_sig.type == new_sig.type then
		score = score + 10
	end

	-- 2. 缩进层级相近：结构特征
	local indent_diff = math.abs(old_sig.indent - new_sig.indent)
	if indent_diff <= 1 then
		score = score + 5
	end

	-- 3. 子节点数量相近：结构复杂度
	local child_diff = math.abs(old_sig.child_count - new_sig.child_count)
	if child_diff <= 1 then
		score = score + 5
	elseif child_diff <= 3 then
		score = score + 2
	end

	-- 4. 任务ID匹配（最高权重）
	if #old_sig.task_ids > 0 or #new_sig.task_ids > 0 then
		if #old_sig.task_ids > 0 and #new_sig.task_ids > 0 then
			-- 都有任务ID：基础分
			score = score + 50

			-- 如果第一个任务ID完全相同，再加高分
			if old_sig.task_ids[1] == new_sig.task_ids[1] then
				score = score + 40
			end
		else
			-- 一个有任务ID一个没有：可能不是同一个块
			score = score - 20
		end
	end

	-- 5. 文本hash相似（弱特征）
	if old_sig.hash ~= "" and new_sig.hash ~= "" then
		if old_sig.hash == new_sig.hash then
			score = score + 15
		else
			-- hash不同但结构相似：轻微扣分
			score = score - 5
		end
	end

	return score
end

---匹配新旧AST中的节点
---@param old_map table[] 旧节点签名表
---@param new_map table[] 新节点签名表
---@param threshold number? 匹配阈值，默认60
---@return table[] 匹配结果，每个元素包含 old 和 new 节点
local function match_nodes(old_map, new_map, threshold)
	threshold = threshold or 60
	local matches = {}
	local used_new = {} -- 标记已匹配的新节点

	for _, old in ipairs(old_map) do
		local best_match = nil
		local best_score = 0
		local best_idx = nil

		for idx, new in ipairs(new_map) do
			-- 跳过已匹配的节点
			if not used_new[idx] then
				local score = calculate_match_score(old.sig, new.sig)

				if score > best_score then
					best_score = score
					best_match = new
					best_idx = idx
				end
			end
		end

		-- 超过阈值才算有效匹配
		if best_match and best_score >= threshold then
			table.insert(matches, {
				old = old.node,
				new = best_match.node,
				score = best_score,
			})
			used_new[best_idx] = true
		end
	end

	return matches
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

---检测移动的代码块
---@param old_ast table 旧AST根节点
---@param new_ast table 新AST根节点
---@param opts? { threshold?: number } 选项，threshold为匹配阈值
---@return table[] 移动块列表，每个元素包含 id, old_start, old_end, new_start, new_end
function M.detect_moves(old_ast, new_ast, opts)
	opts = opts or {}
	local threshold = opts.threshold or 60

	local old_list = flatten_ast(old_ast)
	local new_list = flatten_ast(new_ast)

	local old_map = build_signature_map(old_list)
	local new_map = build_signature_map(new_list)

	local matches = match_nodes(old_map, new_map, threshold)

	local moves = {}

	for _, m in ipairs(matches) do
		local old_node = m.old
		local new_node = m.new

		-- 只关心包含任务ID的块
		if old_node.task_ids and #old_node.task_ids > 0 then
			local id = old_node.task_ids[1] -- 一个块通常只有一个任务ID

			-- 如果行号变了，说明发生了移动
			if old_node.start_line ~= new_node.start_line then
				table.insert(moves, {
					id = id,
					old_start = old_node.start_line,
					old_end = old_node.end_line,
					new_start = new_node.start_line,
					new_end = new_node.end_line,
					confidence = m.score, -- 添加置信度供调试用
				})
			end
		end
	end

	return moves
end

---获取匹配的置信度统计
---@param old_ast table 旧AST根节点
---@param new_ast table 新AST根节点
---@return table 统计信息
function M.get_match_stats(old_ast, new_ast)
	local old_list = flatten_ast(old_ast)
	local new_list = flatten_ast(new_ast)

	local old_map = build_signature_map(old_list)
	local new_map = build_signature_map(new_list)

	local matches = match_nodes(old_map, new_map, 0) -- 阈值为0，获取所有可能匹配

	local stats = {
		total_old = #old_map,
		total_new = #new_map,
		matched = #matches,
		avg_confidence = 0,
		high_confidence = 0, -- >80
		medium_confidence = 0, -- 60-80
		low_confidence = 0, -- <60
	}

	if #matches > 0 then
		local total_score = 0
		for _, m in ipairs(matches) do
			total_score = total_score + m.score
			if m.score >= 80 then
				stats.high_confidence = stats.high_confidence + 1
			elseif m.score >= 60 then
				stats.medium_confidence = stats.medium_confidence + 1
			else
				stats.low_confidence = stats.low_confidence + 1
			end
		end
		stats.avg_confidence = math.floor(total_score / #matches)
	end

	return stats
end

return M
