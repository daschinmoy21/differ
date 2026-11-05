-- One Differ session: a tabpage holding the main pane, the sidebar and the commit
-- box, plus the refresh loop that keeps them in step with the repository.
local M = {}

local api = vim.api
local git = require("differ.git")
local config = require("differ.config")
local highlight = require("differ.highlight")
local ops = require("differ.ops")
local Stream = require("differ.stream")
local Panel = require("differ.panel")
local Split = require("differ.split")

local App = {}
App.__index = App

--- The running session, if any.
M.current = nil

_G.DifferClick = {
  stage_all = function() if M.current then M.current:stage_all() end end,
  toggle_mode = function() if M.current then M.current:toggle_mode() end end,
  commit = function() if M.current then M.current:focus_commit() end end,
  submit = function() if M.current then M.current.panel:commit() end end,
  push = function() if M.current then M.current:remote("Push", { "push" }) end end,
  pull = function() if M.current then M.current:remote("Pull", { "pull", "--ff-only" }) end end,
  tab_changes = function() if M.current then M.current:switch_tab("changes") end end,
  tab_history = function() if M.current then M.current:switch_tab("history") end end,
  help = function() require("differ.help").open() end,
}

local function sorted_files(files)
  local rank = { conflict = 1, tracked = 2, untracked = 3 }
  table.sort(files, function(a, b)
    if a.kind ~= b.kind then
      return (rank[a.kind] or 9) < (rank[b.kind] or 9)
    end
    return a.path < b.path
  end)
  return files
end

function App:common_keymaps(buf)
  local keys = config.options.keys.common
  local function m(lhs, fn, desc)
    if lhs then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Differ: " .. desc })
    end
  end
  m(keys.close, function() self:close() end, "close")
  m(keys.help, function() self:help() end, "help")
  m(keys.refresh, function() self:refresh(true) end, "refresh")
  m(keys.toggle_mode, function() self:toggle_mode() end, "toggle unified / split")
  m(keys.toggle_tab, function() self:toggle_tab() end, "switch Changes / History")
  m(keys.commit, function() self:focus_commit() end, "write commit message")
end

local function create(root, gitdir, opts)
  highlight.setup()
  local self = setmetatable({
    root = root, gitdir = gitdir,
    origin_tab = api.nvim_get_current_tabpage(),
    mode = config.options.mode,
    view = "worktree",
    opts = opts or {},
  }, App)

  vim.cmd("tabnew")
  local placeholder = api.nvim_get_current_buf()
  vim.bo[placeholder].bufhidden = "wipe"
  self.tab = api.nvim_get_current_tabpage()
  self.main_win = api.nvim_get_current_win()

  self.split = Split.new(self)
  self.stream = Stream.new(self, { kind = "worktree", title = "Uncommitted Changes" })
  api.nvim_win_set_buf(self.main_win, self.stream.buf)
  self.stream:attach_window(self.main_win)

  self.panel = Panel.new(self)
  local sidebar = config.options.sidebar
  self.side_win = api.nvim_open_win(self.panel.changes_buf, false, {
    split = sidebar.position == "left" and "left" or "right",
    win = self.main_win,
    width = sidebar.width,
  })
  self.panel:window_options(self.side_win)
  vim.wo[self.side_win].winfixbuf = true
  self:sync_commit_window()
  self.panel:update_winbar()
  self:_autocmds()
  self:_start_poll()
  return self
end

--- Show the commit box exactly when the Changes tab is showing.
function App:sync_commit_window()
  local want = self.panel.tab == "changes"
  local valid = self.commit_win and api.nvim_win_is_valid(self.commit_win)
  if want and not valid then
    self.commit_win = api.nvim_open_win(self.panel.commit_buf, false, {
      split = "below",
      win = self.side_win,
      height = config.options.commit_height,
    })
    local wo = vim.wo[self.commit_win]
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.statuscolumn = ""
    wo.foldcolumn = "0"
    wo.colorcolumn = ""
    wo.spell = false
    wo.wrap = true
    wo.winfixheight = true
    wo.winfixwidth = true
    wo.winfixbuf = true
    wo.fillchars = "eob: "
    wo.statusline = "%#DifferBar#"
    self.panel:update_commit_bar()
  elseif not want and valid then
    api.nvim_win_close(self.commit_win, true)
    self.commit_win = nil
  end
end

function App:focus_commit()
  self:switch_tab("changes")
  if self.commit_win and api.nvim_win_is_valid(self.commit_win) then
    api.nvim_set_current_win(self.commit_win)
    vim.cmd("startinsert!")
  end
end

function App:switch_tab(name)
  if self.panel.tab == name then
    return
  end
  self.panel:show_tab(name)
  if name == "changes" and self.view ~= "worktree" then
    self:show_worktree()
  elseif name == "history" and self.view == "worktree" then
    -- Coming back to History: pick up the commit you were looking at.
    local hash = self.panel.current_commit
    for _, commit in ipairs(hash and self.panel.commits or {}) do
      if commit.hash == hash then
        self:show_commit(commit)
        break
      end
    end
  end
end

--- Switch sidebar tab from anywhere, and focus it so j/k work straight away.
function App:toggle_tab()
  self:switch_tab(self.panel.tab == "changes" and "history" or "changes")
  if api.nvim_win_is_valid(self.side_win) then
    api.nvim_set_current_win(self.side_win)
  end
end

-- Refresh ------------------------------------------------------------------

function App:refresh(force)
  if self.closed then
    return
  end
  if self.refreshing then
    self.refresh_again = true
    return
  end
  self.refreshing = true
  git.status(self.root, function(status, err)
    self.refreshing = false
    if self.closed then
      return
    end
    if not status then
      ops.notify("git status failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if force then
      self.stream.signature = nil
    end
    sorted_files(status.files)
    self.stream:set_files(status.files, function()
      if self.closed then
        return
      end
      self.panel:set_status(status)
      self.split:sync()
      if self.panel.current_path == nil and status.files[1] and self.view == "worktree" then
        self.panel:set_current(status.files[1].path)
      end
      if self.pending_show then
        local pending = self.pending_show
        self.pending_show = nil
        pending()
      end
      if self.refresh_again then
        self.refresh_again = false
        self:refresh()
      end
    end)
  end)
end

function App:_start_poll()
  local ms = config.options.poll_ms
  if not ms or ms <= 0 then
    return
  end
  self.poll = vim.uv.new_timer()
  self.poll:start(ms, ms, vim.schedule_wrap(function()
    if not self.closed and self.focused ~= false and api.nvim_get_current_tabpage() == self.tab then
      self:refresh()
    end
  end))
end

function App:_autocmds()
  local group = api.nvim_create_augroup("differ.app", { clear = true })
  self.group = group
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlight.setup })
  api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if vim.startswith(ev.file or "", "differ://") then
        return
      end
      self:refresh()
    end,
  })
  api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      self.focused = true
      self:refresh()
    end,
  })
  api.nvim_create_autocmd("FocusLost", {
    group = group,
    callback = function() self.focused = false end,
  })
  api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      if api.nvim_get_current_tabpage() == self.tab then
        self:refresh()
      end
    end,
  })
  -- Closing the main pane or the sidebar by hand closes the whole view, and a
  -- :tabclose from anywhere cleans up.
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win == self.main_win or win == self.side_win then
        vim.schedule(function()
          if not self.closed then
            self:close(true)
          end
        end)
      end
    end,
  })
  api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      if not api.nvim_tabpage_is_valid(self.tab) then
        self:_cleanup()
      end
    end,
  })
end

-- Views --------------------------------------------------------------------

function App:active_stream()
  return self.view == "commit" and self.commit_stream or self.stream
end

function App:_show_stream(stream)
  if self.split:is_open() then
    self.split:close()
  end
  api.nvim_win_set_buf(self.main_win, stream.buf)
  stream:attach_window(self.main_win)
  stream:update_winbar()
end

--- Back to Uncommitted Changes.
function App:show_worktree()
  self.view = "worktree"
  if self.mode == "split" and self.stream.files[1] then
    local path = self.panel.current_path
    local file = path and self.stream.by_path[path] or self.stream.files[1]
    self.split:show(self.stream, file)
  else
    self:_show_stream(self.stream)
  end
end

--- Show a file of the worktree stream in the current mode.
function App:show_file(path, opts)
  self.view = "worktree"
  local file = self.stream.by_path[path]
  if not file then
    return
  end
  self.panel:set_current(path)
  if self.mode == "split" then
    self.split:show(self.stream, file)
    return
  end
  if api.nvim_win_get_buf(self.main_win) ~= self.stream.buf then
    self:_show_stream(self.stream)
  end
  self.stream:jump_to(path, opts)
end

--- Called when the cursor enters a different file in a stream.
function App:on_stream_file(stream, path)
  if stream.kind == "worktree" and path then
    self.panel:set_current(path)
  end
end

function App:show_commit(commit, path)
  local root = self.root
  self.view = "commit"
  local token = {}
  self.commit_token = token
  local base = commit.parents[1] or git.empty_tree(root)
  git.commit_info(root, commit.hash, function(info)
    if self.commit_token ~= token or self.closed then
      return
    end
    local rows = {}
    if info then
      local body = vim.split(info.body, "\n", { plain = true })
      rows[#rows + 1] = { text = "  " .. (body[1] or ""), hl = "DifferInfoTitle" }
      for i = 2, #body do
        rows[#rows + 1] = { text = "  " .. body[i], hl = "DifferInfo" }
      end
      rows[#rows + 1] = { text = "", hl = "DifferInfo" }
      local meta = ("  %s  ·  %s  ·  %s"):format(
        info.author, os.date("%Y-%m-%d %H:%M", info.time), commit.hash
      )
      rows[#rows + 1] = { text = meta, hl = "DifferInfo" }
      if #commit.parents > 1 then
        rows[#rows + 1] = { text = "  Merge: showing changes against the first parent " .. commit.parents[1]:sub(1, 8), hl = "DifferNote" }
      end
    end
    git.diff_files(root, base, commit.hash, function(files)
      if self.commit_token ~= token or self.closed then
        return
      end
      local stream = Stream.new(self, {
        kind = "commit",
        base = base,
        rev = commit.hash,
        title = commit.short .. " " .. commit.subject,
        info = rows,
      })
      stream:set_files(files, function()
        if self.commit_token ~= token or self.closed then
          return stream:destroy()
        end
        local old = self.commit_stream
        self.commit_stream = stream
        if self.mode == "split" and files[1] then
          local file = path and stream.by_path[path] or files[1]
          self.split:show(stream, file)
        else
          self:_show_stream(stream)
          if path then
            stream:jump_to(path, { force = true })
          end
        end
        if old then
          old:destroy()
        end
      end)
    end)
  end)
end

function App:toggle_mode()
  local stream = self:active_stream()
  if self.mode == "unified" then
    local r = stream:win() and stream:row_at_cursor()
    local path = (r and r.f and r.f.path) or self.panel.current_path
    local file = path and stream.by_path[path] or stream.files[1]
    if not file then
      return ops.notify("No files to compare", vim.log.levels.WARN)
    end
    self.mode = "split"
    self.split:show(stream, file)
  else
    local path = self.split.file and self.split.file.path
    self.mode = "unified"
    self:_show_stream(stream)
    if path then
      stream:jump_to(path)
    end
  end
end

--- Move to the next or previous file (used by split mode).
function App:step_file(dir)
  local stream = self:active_stream()
  local current = self.split.file and self.split.file.path
  for i, f in ipairs(stream.files) do
    if f.path == current then
      local nxt = stream.files[i + dir]
      if nxt then
        self.split:show(stream, nxt)
      end
      return
    end
  end
end

-- Open real files ----------------------------------------------------------

function App:open_file(path, line)
  local full = self.root .. "/" .. path
  if not vim.uv.fs_stat(full) then
    return ops.notify(path .. " doesn't exist in the working tree", vim.log.levels.WARN)
  end
  if self.origin_tab and api.nvim_tabpage_is_valid(self.origin_tab) then
    api.nvim_set_current_tabpage(self.origin_tab)
  else
    vim.cmd("tabnew")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(full))
  pcall(api.nvim_win_set_cursor, 0, { line or 1, 0 })
  vim.cmd("normal! zz")
end

-- Repository actions -------------------------------------------------------

function App:toggle_files(files)
  if #files == 0 then
    return
  end
  local all_staged = true
  for _, f in ipairs(files) do
    if Stream.stage_of(f) ~= "full" then
      all_staged = false
      break
    end
  end
  if all_staged then
    ops.unstage_files(self.root, files)
  else
    ops.stage_files(self.root, files)
  end
  self:refresh()
end

function App:stage_all()
  git.sync(self.root, { "add", "-A" })
  self:refresh()
end

function App:unstage_all()
  git.sync(self.root, { "reset", "-q" })
  self:refresh()
end

function App:remote(verb, args)
  ops.remote(self.root, verb, args, function()
    if self.closed then
      return
    end
    self.panel:reset_history()
    if self.panel.tab == "history" then
      self.panel:load_history()
    end
    self:refresh()
  end)
end

-- Help ---------------------------------------------------------------------

function App:help()
  require("differ.help").open()
end

-- Lifecycle ----------------------------------------------------------------

function App:_cleanup()
  if self.closed then
    return
  end
  self.closed = true
  if self.poll then
    self.poll:stop()
    self.poll:close()
    self.poll = nil
  end
  pcall(api.nvim_del_augroup_by_id, self.group)
  self.split:_unmap()
  self.panel:destroy()
  self.stream:destroy()
  if self.commit_stream then
    self.commit_stream:destroy()
  end
  if M.current == self then
    M.current = nil
  end
end

--- Close the view. Unsaved edits ask first unless `forced`.
function App:close(forced)
  if self.closed then
    return
  end
  if self.stream:is_dirty() and not forced then
    local choice = vim.fn.confirm("You have unsaved edits in the diff.", "&Write them\n&Discard\n&Cancel", 3)
    if choice == 1 then
      if not self.stream:save() then
        return
      end
    elseif choice ~= 2 then
      return
    end
  end
  local tab = self.tab
  local origin = self.origin_tab
  if api.nvim_tabpage_is_valid(tab) then
    pcall(api.nvim_del_augroup_by_id, self.group)
    if #api.nvim_list_tabpages() == 1 then
      vim.cmd("tabnew") -- never close the last tab out from under the user
    end
    local nr = api.nvim_tabpage_get_number(tab)
    vim.cmd("silent! " .. nr .. "tabclose!")
    if origin and api.nvim_tabpage_is_valid(origin) then
      api.nvim_set_current_tabpage(origin)
    end
  end
  self:_cleanup()
end

function App:focus()
  api.nvim_set_current_tabpage(self.tab)
  self:refresh()
end

-- Entry points -------------------------------------------------------------

local function start(path)
  local root, gitdir = git.find_root(path or vim.fn.expand("%:p"))
  if not root then
    ops.notify("Not inside a git repository", vim.log.levels.WARN)
    return nil
  end
  if M.current and M.current.root ~= root then
    M.current:close()
  end
  if M.current then
    M.current:focus()
    return M.current
  end
  M.current = create(root, gitdir)
  return M.current
end
M.start = start

function M.open(opts)
  opts = opts or {}
  local app = start(opts.path)
  if app then
    app:refresh()
  end
  return app
end

function M.toggle()
  local app = M.current
  if app and api.nvim_get_current_tabpage() == app.tab then
    app:close()
  else
    M.open()
  end
end

function M.history(path)
  local app = start(path)
  if not app then
    return
  end
  if path then
    local rel = vim.fs.relpath and vim.fs.relpath(app.root, path)
    app.panel.hist_path = rel or path
  else
    app.panel.hist_path = nil
  end
  app.panel:reset_history()
  app.panel.tab = "changes"
  app:refresh()
  app.panel:show_tab("history")
  api.nvim_set_current_win(app.side_win)
end

return M
