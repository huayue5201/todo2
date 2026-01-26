-- lua/todo2/store/types.lua
--- @module todo2.store.types

local M = {}

--- @alias TodoId string

--- @class TodoLink
--- @field id string
--- @field type string
--- @field path string
--- @field line number
--- @field content string
--- @field created_at number
--- @field updated_at number
--- @field active boolean
--- @field context table|nil

--- @class ContextFingerprint
--- @field hash string
--- @field struct string|nil
--- @field n_prev string
--- @field n_curr string
--- @field n_next string
--- @field window_hash string

--- @class Context
--- @field raw table
--- @field fingerprint ContextFingerprint

--- @class MetaData
--- @field initialized boolean
--- @field version string
--- @field created_at number
--- @field last_sync number
--- @field total_links number
--- @field project_root string

--- @enum LinkType
M.LINK_TYPES = {
	CODE_TO_TODO = "code_to_todo",
	TODO_TO_CODE = "todo_to_code",
}

return M
