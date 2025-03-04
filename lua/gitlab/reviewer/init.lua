-- This Module contains all of the reviewer code. This is the code
-- that parses or interacts with diffview directly, such as opening
-- and closing, getting metadata about the current view, and registering
-- callbacks for open/close actions.

local List = require("gitlab.utils.list")
local u = require("gitlab.utils")
local state = require("gitlab.state")
local git = require("gitlab.git")
local hunks = require("gitlab.hunks")
local async = require("diffview.async")
local diffview_lib = require("diffview.lib")

local M = {
  bufnr = nil,
  tabnr = nil,
  stored_win = nil,
}

-- Checks for legacy installations, only Diffview is supported.
M.init = function()
  if state.settings.reviewer ~= "diffview" then
    vim.notify(
      string.format("gitlab.nvim could not find reviewer %s, only diffview is supported", state.settings.reviewer),
      vim.log.levels.ERROR
    )
  end
end

-- Opens the reviewer window.
M.open = function()
  local diff_refs = state.INFO.diff_refs
  if diff_refs == nil then
    u.notify("Gitlab did not provide diff refs required to review this MR", vim.log.levels.ERROR)
    return
  end

  if diff_refs.base_sha == "" or diff_refs.head_sha == "" then
    u.notify("Merge request contains no changes", vim.log.levels.ERROR)
    return
  end

  local diffview_open_command = "DiffviewOpen"
  local has_clean_tree = git.has_clean_tree()
  if state.settings.reviewer_settings.diffview.imply_local and has_clean_tree then
    diffview_open_command = diffview_open_command .. " --imply-local"
  end

  vim.api.nvim_command(string.format("%s %s..%s", diffview_open_command, diff_refs.base_sha, diff_refs.head_sha))
  M.tabnr = vim.api.nvim_get_current_tabpage()

  if state.settings.reviewer_settings.diffview.imply_local and not has_clean_tree then
    u.notify(
      "There are uncommited changes in the working tree, cannot use 'imply_local' setting for gitlab reviews.\n Stash or commit all changes to use.",
      vim.log.levels.WARN
    )
  end

  if state.INFO.has_conflicts then
    u.notify("This merge request has conflicts!", vim.log.levels.WARN)
  end

  if state.settings.discussion_diagnostic ~= nil or state.settings.discussion_sign ~= nil then
    u.notify(
      "Diagnostics are now configured as settings.discussion_signs, see :h gitlab.nvim.signs-and-diagnostics",
      vim.log.levels.WARN
    )
  end

  -- Register Diffview hook for close event to set tab page # to nil
  local on_diffview_closed = function(view)
    if view.tabpage == M.tabnr then
      M.tabnr = nil
    end
  end
  require("diffview.config").user_emitter:on("view_closed", function(_, ...)
    on_diffview_closed(...)
  end)

  if state.settings.discussion_tree.auto_open then
    local discussions = require("gitlab.actions.discussions")
    discussions.close()
    discussions.toggle()
  end
end

-- Closes the reviewer and cleans up
M.close = function()
  vim.cmd("DiffviewClose")
  local discussions = require("gitlab.actions.discussions")
  discussions.close()
end

-- Jumps to the location provided in the reviewer window
---@param file_name string
---@param line_number number
---@param new_buffer boolean
M.jump = function(file_name, line_number, new_buffer)
  if M.tabnr == nil then
    u.notify("Can't jump to Diffvew. Is it open?", vim.log.levels.ERROR)
    return
  end
  vim.api.nvim_set_current_tabpage(M.tabnr)
  vim.cmd("DiffviewFocusFiles")
  local view = diffview_lib.get_current_view()
  if view == nil then
    u.notify("Could not find Diffview view", vim.log.levels.ERROR)
    return
  end

  local files = view.panel:ordered_file_list()
  local file = List.new(files):find(function(file)
    return file.path == file_name
  end)
  async.await(view:set_file(file))

  local layout = view.cur_layout
  local number_of_lines
  if new_buffer then
    layout.b:focus()
    number_of_lines = u.get_buffer_length(layout.b.file.bufnr)
  else
    layout.a:focus()
    number_of_lines = u.get_buffer_length(layout.a.file.bufnr)
  end
  if line_number > number_of_lines then
    u.notify("Diagnostic position outside buffer. Jumping to last line instead.", vim.log.levels.WARN)
    line_number = number_of_lines
  end
  vim.api.nvim_win_set_cursor(0, { line_number, 0 })
end

---Get the data from diffview, such as line information and file name. May be used by
---other modules such as the comment module to create line codes or set diagnostics
---@return DiffviewInfo | nil
M.get_reviewer_data = function()
  if M.tabnr == nil then
    u.notify("Diffview reviewer must be initialized first", vim.log.levels.ERROR)
    return
  end

  -- Check if we are in the diffview tab
  local tabnr = vim.api.nvim_get_current_tabpage()
  if tabnr ~= M.tabnr then
    u.notify("Line location can only be determined within reviewer window", vim.log.levels.ERROR)
    return
  end

  -- Check if we are in the diffview buffer
  local view = diffview_lib.get_current_view()
  if view == nil then
    u.notify("Could not find Diffview view", vim.log.levels.ERROR)
    return
  end

  local layout = view.cur_layout
  local old_win = u.get_window_id_by_buffer_id(layout.a.file.bufnr)
  local new_win = u.get_window_id_by_buffer_id(layout.b.file.bufnr)

  if old_win == nil or new_win == nil then
    u.notify("Error getting window IDs for current files", vim.log.levels.ERROR)
    return
  end

  local current_file = M.get_current_file()
  if current_file == nil then
    u.notify("Error getting current file from Diffview", vim.log.levels.ERROR)
    return
  end

  local new_line = vim.api.nvim_win_get_cursor(new_win)[1]
  local old_line = vim.api.nvim_win_get_cursor(old_win)[1]

  local is_current_sha_focused = M.is_current_sha_focused()
  local modification_type = hunks.get_modification_type(old_line, new_line, current_file, is_current_sha_focused)
  if modification_type == nil then
    u.notify("Error getting modification type", vim.log.levels.ERROR)
    return
  end

  if modification_type == "bad_file_unmodified" then
    u.notify("Comments on unmodified lines will be placed in the old file", vim.log.levels.WARN)
  end

  local current_bufnr = is_current_sha_focused and layout.b.file.bufnr or layout.a.file.bufnr
  local opposite_bufnr = is_current_sha_focused and layout.a.file.bufnr or layout.b.file.bufnr
  local old_sha_win_id = u.get_window_id_by_buffer_id(layout.a.file.bufnr)
  local new_sha_win_id = u.get_window_id_by_buffer_id(layout.b.file.bufnr)

  return {
    file_name = layout.a.file.path,
    old_line_from_buf = old_line,
    new_line_from_buf = new_line,
    modification_type = modification_type,
    new_sha_win_id = new_sha_win_id,
    current_bufnr = current_bufnr,
    old_sha_win_id = old_sha_win_id,
    opposite_bufnr = opposite_bufnr,
  }
end

---Return whether user is focused on the new version of the file
---@return boolean
M.is_current_sha_focused = function()
  local view = diffview_lib.get_current_view()
  local layout = view.cur_layout
  local b_win = u.get_window_id_by_buffer_id(layout.b.file.bufnr)
  local a_win = u.get_window_id_by_buffer_id(layout.a.file.bufnr)
  local current_win = vim.fn.win_getid()

  -- Handle cases where user navigates tabs in the middle of making a comment
  if a_win ~= current_win and b_win ~= current_win then
    current_win = M.stored_win
    M.stored_win = nil
  end
  return current_win == b_win
end

---Get currently shown file
---@return string|nil
M.get_current_file = function()
  local view = diffview_lib.get_current_view()
  if not view then
    return
  end
  return view.panel.cur_file.path
end

---Diffview exposes events which can be used to setup autocommands.
---@param callback fun(opts: table) - for more information about opts see callback in :h nvim_create_autocmd
M.set_callback_for_file_changed = function(callback)
  local group = vim.api.nvim_create_augroup("gitlab.diffview.autocommand.file_changed", {})
  vim.api.nvim_create_autocmd("User", {
    pattern = { "DiffviewDiffBufWinEnter" },
    group = group,
    callback = function(...)
      M.stored_win = vim.api.nvim_get_current_win()
      if M.tabnr == vim.api.nvim_get_current_tabpage() then
        callback(...)
      end
    end,
  })
end

---Diffview exposes events which can be used to setup autocommands.
---@param callback fun(opts: table) - for more information about opts see callback in :h nvim_create_autocmd
M.set_callback_for_reviewer_leave = function(callback)
  local group = vim.api.nvim_create_augroup("gitlab.diffview.autocommand.leave", {})
  vim.api.nvim_create_autocmd("User", {
    pattern = { "DiffviewViewLeave", "DiffviewViewClosed" },
    group = group,
    callback = function(...)
      if M.tabnr == vim.api.nvim_get_current_tabpage() then
        callback(...)
      end
    end,
  })
end

M.set_callback_for_reviewer_enter = function(callback)
  local group = vim.api.nvim_create_augroup("gitlab.diffview.autocommand.enter", {})
  vim.api.nvim_create_autocmd("User", {
    pattern = { "DiffviewViewOpened" },
    group = group,
    callback = function(...)
      callback(...)
    end,
  })
end

return M
