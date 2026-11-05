-- The sidebar: a Changes tab (file list, stage state, commit box) and a History
-- tab (commit graph). Both are ordinary read-only buffers in ordinary windows.
local M = {}

local api = vim.api
local git = require("differ.git")
local graph = require("differ.graph")
local config = require("differ.config")
local ops = require("differ.ops")

local NS = api.nvim_create_namespace("differ.panel")
local NS_CUR = api.nvim_create_namespace("differ.panel.current")

local Panel = {}
Panel.__index = Panel

local function devicon(name)
  local ok, icons = pcall(require, "nvim-web-devicons")
  if not ok then
    return nil
  end
  local ext = name:match("%.([^.]+)$")
  return icons.get_icon(name, ext, { default = true })
end

local function scratch(name, ft)
  local buf = api.nvim_create_buf(false, true)
  pcall(api.nvim_buf_set_name, buf, name)
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.buflisted = false
  bo.modifiable = false
  bo.filetype = ft
  pcall(function()
    require("ibl").setup_buffer(buf, { enabled = false })
  end)
  return buf
end

function M.new(app)
  local self = setmetatable({
    app = app,
    tab = "changes",
    items = {},
    hist_items = {},
    collapsed = {},
    commits = {},
    graph = graph.new(),
    hist_all = config.options.history.all,
    expanded = {},
  }, Panel)
  self.changes_buf = scratch("differ://panel/changes", "differ-panel")
  self.history_buf = scratch("differ://panel/history", "differ-panel")
  self.commit_buf = self:_make_commit_buf()
  self:_changes_keys()
  self:_history_keys()
  self:_autocmds()
  return self
end

function Panel:destroy()
  for _, t in ipairs({ "follow_timer", "hist_timer" }) do
    if self[t] then
      self[t]:stop()
      self[t]:close()
      self[t] = nil
    end
  end
  for _, buf in ipairs({ self.changes_buf, self.history_buf, self.commit_buf }) do
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function Panel:window_options(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.colorcolumn = ""
  wo.statuscolumn = ""
  wo.spell = false
  wo.list = false
  wo.wrap = false
  wo.cursorline = true
  wo.winfixwidth = true
  wo.fillchars = "eob: "
  wo.statusline = "%#DifferBar#"
end

-- Tabs ---------------------------------------------------------------------

function Panel:update_winbar()
  local win = self.app.side_win
  if not win or not api.nvim_win_is_valid(win) then
    return
  end
  local count = self.status and #self.status.files or 0
  local function tab(fn, text, active)
    return ("%%#%s#%%@v:lua.DifferClick.%s@  %s  %%X"):format(active and "DifferTabActive" or "DifferTab", fn, text)
  end
  local bar = tab("tab_changes", ("Changes (%d)"):format(count), self.tab == "changes")
    .. tab("tab_history", "History", self.tab == "history")
    .. "%#DifferTab#%="
    .. (config.options.keys.common.toggle_tab or "") .. " ⇄ "
    .. "%#DifferBarBtn#%@v:lua.DifferClick.help@ ? Help %X%#DifferTab# "
  vim.wo[win].winbar = bar
end

function Panel:show_tab(name)
  self.tab = name
  local win = self.app.side_win
  if not win or not api.nvim_win_is_valid(win) then
    return
  end
  local buf = name == "changes" and self.changes_buf or self.history_buf
  vim.wo[win].winfixbuf = false
  api.nvim_win_set_buf(win, buf)
  vim.wo[win].winfixbuf = true
  self:window_options(win)
  self:update_winbar()
  self.app:sync_commit_window()
  if name == "history" and #self.commits == 0 then
    self:load_history()
  end
end

-- Changes tab --------------------------------------------------------------

local function status_letter(file)
  if file.kind == "conflict" then return "C" end
  if file.kind == "untracked" then return "U" end
  local c = file.y ~= "." and file.y or file.x
  if c == "T" then return "M" end
  return c
end

local function is_deleted(file)
  return file.x == "D" or file.y == "D"
end

function Panel:section_files(name)
  local out = {}
  for _, file in ipairs(self.status and self.status.files or {}) do
    if file.kind == name then
      out[#out + 1] = file
    end
  end
  return out
end

local function stage_icon(state)
  local icons = config.options.icons
  if state == "full" then
    return icons.checked, "DifferPanelChecked"
  elseif state == "partial" then
    return icons.partial, "DifferPanelChecked"
  end
  return icons.unchecked, "DifferPanelCheck"
end

local function section_state(files)
  local staged = 0
  for _, f in ipairs(files) do
    local s = require("differ.stream").stage_of(f)
    if s == "full" then
      staged = staged + 1
    elseif s == "partial" then
      return "partial"
    end
  end
  if staged == 0 then return "none" end
  return staged == #files and "full" or "partial"
end

function Panel:set_status(status)
  local sig = {
    status.branch, status.ahead, status.behind, status.upstream or "",
    next(self.collapsed) and vim.inspect(self.collapsed) or "",
  }
  for _, f in ipairs(status.files) do
    sig[#sig + 1] = table.concat({ f.path, f.x, f.y, f.adds or "", f.dels or "" }, "|")
  end
  sig = table.concat(sig, "\n")
  self.status = status
  if sig ~= self.status_sig then
    self.status_sig = sig
    self:render_changes()
  end
  self:update_winbar()
  self:update_commit_bar()
end

function Panel:render_changes()
  local status = self.status
  local buf = self.changes_buf
  local lines, items, marks = {}, {}, {}
  local adds, dels = 0, 0
  for _, f in ipairs(status.files) do
    adds, dels = adds + (f.adds or 0), dels + (f.dels or 0)
  end
  local function push(text, item)
    lines[#lines + 1] = text
    items[#items + 1] = item
    return #lines - 1
  end
  local function hl(row, s, e, group)
    marks[#marks + 1] = { row, s, { end_col = e, hl_group = group } }
  end
  local function right(row, chunks)
    marks[#marks + 1] = { row, 0, { virt_text = chunks, virt_text_pos = "right_align" } }
  end

  local keys = config.options.keys.changes
  local row = push(" View Diff", { k = "summary" })
  hl(row, 0, #lines[row + 1], "DifferPanelSection")
  right(row, {
    { "+" .. adds, "DifferAddText" }, { " −" .. dels .. "  ", "DifferDelText" },
    { " " .. (keys.stage_all or "a") .. " Stage All ", "DifferHintAlt" }, { " ", "Normal" },
  })

  local icons = config.options.icons
  for _, sec in ipairs({ { "conflict", "Conflicts" }, { "tracked", "Tracked" }, { "untracked", "Untracked" } }) do
    local name, label = sec[1], sec[2]
    local files = self:section_files(name)
    if #files > 0 then
      local collapsed = self.collapsed[name]
      row = push((" %s %s"):format(collapsed and icons.collapsed or icons.expanded, label), { k = "section", name = name, files = files })
      hl(row, 0, #lines[row + 1], "DifferPanelSection")
      local check, check_hl = stage_icon(section_state(files))
      right(row, { { tostring(#files) .. "  ", "DifferPanelCount" }, { check .. " ", check_hl } })
      if not collapsed then
        for _, f in ipairs(files) do
          local base = vim.fs.basename(f.path)
          local dir = vim.fs.dirname(f.path)
          local letter = status_letter(f)
          local icon, icon_hl = devicon(base)
          local prefix = "  " .. letter .. " "
          local icon_text = icon and (icon .. " ") or ""
          local text = prefix .. icon_text .. base .. (dir ~= "." and (" " .. dir) or "")
          row = push(text, { k = "file", file = f })
          hl(row, 0, #prefix, "DifferStatus" .. (letter:match("[MADRUC]") or "M"))
          if icon_hl then
            hl(row, #prefix, #prefix + #icon_text, icon_hl)
          end
          local name_s = #prefix + #icon_text
          if is_deleted(f) then
            hl(row, name_s, name_s + #base, "DifferPanelDeleted")
          end
          hl(row, name_s + #base, #text, "DifferPanelDir")
          local chunks = {}
          if f.binary then
            chunks[#chunks + 1] = { "bin ", "DifferPanelDir" }
          else
            chunks[#chunks + 1] = { "+" .. (f.adds or 0), "DifferAddText" }
            chunks[#chunks + 1] = { " −" .. (f.dels or 0) .. " ", "DifferDelText" }
          end
          local c, c_hl = stage_icon(require("differ.stream").stage_of(f))
          chunks[#chunks + 1] = { " " .. c .. " ", c_hl }
          right(row, chunks)
        end
      end
    end
  end
  if #status.files == 0 then
    row = push("  Working tree clean", { k = "empty" })
    hl(row, 0, #lines[row + 1], "DifferNote")
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  self.items = items
  api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, m in ipairs(marks) do
    pcall(api.nvim_buf_set_extmark, buf, NS, m[1], m[2], m[3])
  end
  self:set_current(self.current_path)
end

--- Mark a file as current. Moves the list's cursor unless you're in the list.
function Panel:set_current(path)
  self.current_path = path
  local buf = self.changes_buf
  api.nvim_buf_clear_namespace(buf, NS_CUR, 0, -1)
  if not path then
    return
  end
  for i, item in ipairs(self.items) do
    if item.k == "file" and item.file.path == path then
      pcall(api.nvim_buf_set_extmark, buf, NS_CUR, i - 1, 0, { line_hl_group = "DifferPanelCurrent", priority = 10 })
      local win = self.app.side_win
      if win and api.nvim_win_is_valid(win) and api.nvim_get_current_win() ~= win
        and api.nvim_win_get_buf(win) == buf then
        pcall(api.nvim_win_set_cursor, win, { i, 0 })
      end
      return
    end
  end
end

function Panel:item_at_cursor()
  local win = self.app.side_win
  local line = api.nvim_win_get_cursor(win)[1]
  return self.items[line], line
end

local function files_in(items, a, b)
  local out, seen = {}, {}
  for i = a, b do
    local item = items[i]
    if item and item.k == "file" and not seen[item.file.path] then
      seen[item.file.path] = true
      out[#out + 1] = item.file
    elseif item and item.k == "section" then
      for _, f in ipairs(item.files) do
        if not seen[f.path] then
          seen[f.path] = true
          out[#out + 1] = f
        end
      end
    end
  end
  return out
end

function Panel:_target_files(visual)
  if visual then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    return files_in(self.items, math.min(a, b), math.max(a, b))
  end
  local _, line = self:item_at_cursor()
  return files_in(self.items, line, line)
end

function Panel:_activate_change(item)
  if not item then
    return
  end
  if item.k == "section" then
    self.collapsed[item.name] = not self.collapsed[item.name] or nil
    self:render_changes()
    return
  end
  if item.k == "summary" then
    self.app:show_worktree()
    return
  end
  if item.k == "file" then
    self.app:show_file(item.file.path, { force = true })
  end
end

function Panel:_on_changes_mouse()
  local pos = vim.fn.getmousepos()
  local win = self.app.side_win
  if pos.winid ~= win or vim.fn.mode() ~= "n" then
    return
  end
  local item = self.items[pos.line]
  if not item then
    return
  end
  local from_right = api.nvim_win_get_width(win) - pos.wincol
  if item.k == "summary" and from_right < 14 then
    return self.app:stage_all()
  end
  if (item.k == "file" or item.k == "section") and from_right < 3 then
    return self.app:toggle_files(files_in(self.items, pos.line, pos.line))
  end
  self:_activate_change(item)
end

function Panel:_map(buf, lhs, fn, desc, mode)
  if lhs then
    vim.keymap.set(mode or "n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Differ: " .. desc })
  end
end

function Panel:_changes_keys()
  local buf, keys, app = self.changes_buf, config.options.keys.changes, self.app
  local function m(lhs, fn, desc, mode)
    self:_map(buf, lhs, fn, desc, mode)
  end
  m(keys.activate, function() self:_activate_change(self:item_at_cursor()) end, "show file / fold section")
  m(keys.toggle_section, function()
    local item, line = self:item_at_cursor()
    if item and item.k == "file" then
      for i = line, 1, -1 do
        if self.items[i].k == "section" then
          item = self.items[i]
          api.nvim_win_set_cursor(app.side_win, { i, 0 })
          break
        end
      end
    end
    if item and item.k == "section" then
      self:_activate_change(item)
    end
  end, "fold section")
  m(keys.toggle, function() app:toggle_files(self:_target_files()) end, "toggle stage")
  m(keys.toggle, function() app:toggle_files(self:_target_files(true)) end, "toggle stage", "x")
  m(keys.stage, function() ops.stage_files(app.root, self:_target_files()); app:refresh() end, "stage")
  m(keys.stage, function() ops.stage_files(app.root, self:_target_files(true)); app:refresh() end, "stage", "x")
  m(keys.unstage, function() ops.unstage_files(app.root, self:_target_files()); app:refresh() end, "unstage")
  m(keys.unstage, function() ops.unstage_files(app.root, self:_target_files(true)); app:refresh() end, "unstage", "x")
  m(keys.restore, function()
    if ops.discard_files(app.root, self:_target_files()) then app:refresh() end
  end, "discard changes")
  m(keys.restore, function()
    if ops.discard_files(app.root, self:_target_files(true)) then app:refresh() end
  end, "discard changes", "x")
  m(keys.stage_all, function() app:stage_all() end, "stage all")
  m(keys.unstage_all, function() app:unstage_all() end, "unstage all")
  m(keys.commit, function() app:focus_commit() end, "write commit message")
  m(keys.push, function() app:remote("Push", { "push" }) end, "push")
  m(keys.pull, function() app:remote("Pull", { "pull", "--ff-only" }) end, "pull (fast-forward)")
  m(keys.fetch, function() app:remote("Fetch", { "fetch", "--all", "--prune" }) end, "fetch")
  m(keys.help, function() app:help() end, "help")
  m(keys.next_tab, function() app:switch_tab("history") end, "History tab")
  m(keys.prev_tab, function() app:switch_tab("history") end, "History tab")
  vim.keymap.set("n", "<LeftRelease>", function() self:_on_changes_mouse() end, { buffer = buf, silent = true })
  app:common_keymaps(buf)
end

-- History tab --------------------------------------------------------------

function Panel:reset_history()
  self.commits = {}
  self.hist_items = {}
  self.expanded = {}
  self.graph = graph.new()
  self.hist_done = false
  self.hist_token = (self.hist_token or 0) + 1
end

function Panel:load_history(cb)
  if self.hist_loading or self.hist_done then
    return
  end
  self.hist_loading = true
  local token = self.hist_token
  local page = config.options.history.page
  git.log(self.app.root, {
    count = page, skip = #self.commits, all = self.hist_all, path = self.hist_path,
  }, function(commits)
    self.hist_loading = false
    if token ~= self.hist_token or not api.nvim_buf_is_valid(self.history_buf) then
      return
    end
    commits = commits or {}
    if #commits < page then
      self.hist_done = true
    end
    for _, c in ipairs(commits) do
      local head = c.refs:find("HEAD", 1, true) ~= nil
      c.row = self.graph:add(c.hash, c.parents, head and "head" or nil)
      self.commits[#self.commits + 1] = c
    end
    self:render_history()
    if cb then
      cb()
    end
  end)
end

local function cells_text(cells, max_cells)
  local text, spans = {}, {}
  local col = 0
  local limit = math.min(#cells, max_cells)
  for i = 1, limit do
    local c = cells[i]
    text[#text + 1] = c[1]
    if c[1] ~= " " then
      local last = spans[#spans]
      if last and last.color == c[2] and last.e == col then
        last.e = col + #c[1]
      else
        spans[#spans + 1] = { s = col, e = col + #c[1], color = c[2] }
      end
    end
    col = col + #c[1]
  end
  return table.concat(text), spans, limit
end

local function ref_badges(refs)
  local out = {}
  if refs == "" then
    return out
  end
  for _, ref in ipairs(vim.split(refs, ", ", { plain = true })) do
    local name, hl = ref, "DifferRef"
    if ref:match("^HEAD %-> ") then
      name, hl = ref:gsub("^HEAD %-> ", ""), "DifferRefHead"
    elseif ref == "HEAD" then
      hl = "DifferRefHead"
    elseif ref:match("^tag: ") then
      name, hl = ref:gsub("^tag: ", ""), "DifferRefTag"
    elseif ref:find("/", 1, true) then
      hl = "DifferRefRemote"
    end
    out[#out + 1] = { text = name, hl = hl }
  end
  return out
end

function Panel:render_history()
  local buf = self.history_buf
  local max_cells = config.options.history.max_lanes * 2 - 1
  local lines, items, marks = {}, {}, {}
  local function hl(row, s, e, group)
    marks[#marks + 1] = { row, s, { end_col = e, hl_group = group } }
  end
  local function graph_prefix(row, cells, pad_to)
    local text, spans, used = cells_text(cells, max_cells)
    for _, sp in ipairs(spans) do
      hl(row, sp.s + 1, sp.e + 1, "DifferGraph" .. sp.color)
    end
    return " " .. text .. string.rep(" ", math.max(pad_to - used, 0))
  end
  local now = os.time()
  for _, c in ipairs(self.commits) do
    local width = math.min(#c.row.cells, max_cells)
    local row = #lines
    local prefix = graph_prefix(row, c.row.cells, width) .. " "
    local parts = { prefix }
    local col = #prefix
    for _, badge in ipairs(ref_badges(c.refs)) do
      local t = " " .. badge.text .. " "
      hl(row, col, col + #t, badge.hl)
      parts[#parts + 1] = t .. " "
      col = col + #t + 1
    end
    parts[#parts + 1] = c.subject
    hl(row, col, col + #c.subject, "DifferCommitSubject")
    lines[#lines + 1] = table.concat(parts)
    items[#items + 1] = { k = "commit", commit = c }

    row = #lines
    prefix = graph_prefix(row, c.row.cont, width) .. " "
    local detail = ("%s • %s • %s"):format(c.author, git.relative_time(c.time, now), c.short)
    hl(row, #prefix, #prefix + #detail, "DifferCommitMeta")
    lines[#lines + 1] = prefix .. detail
    items[#items + 1] = { k = "commit", commit = c, detail = true }

    if self.expanded[c.hash] then
      for _, f in ipairs(self.expanded[c.hash]) do
        row = #lines
        prefix = graph_prefix(row, c.row.cont, width) .. "  "
        local letter = f.x == "R" and "R" or f.x
        local text = letter .. " " .. f.path
        hl(row, #prefix, #prefix + 1, "DifferStatus" .. (letter:match("[MADR]") or "M"))
        hl(row, #prefix + 2, #prefix + #text, "DifferPanelDir")
        lines[#lines + 1] = prefix .. text
        items[#items + 1] = { k = "child", commit = c, file = f }
        marks[#marks + 1] = { row, 0, { virt_text = {
          { "+" .. (f.adds or 0), "DifferAddText" }, { " −" .. (f.dels or 0) .. " ", "DifferDelText" },
        }, virt_text_pos = "right_align" } }
      end
    end
  end
  if #lines == 0 then
    lines[1] = "  No commits yet"
    items[1] = { k = "empty" }
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  self.hist_items = items
  api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, m in ipairs(marks) do
    pcall(api.nvim_buf_set_extmark, buf, NS, m[1], m[2], m[3])
  end
  self:_mark_commit()
end

function Panel:_mark_commit()
  local buf = self.history_buf
  api.nvim_buf_clear_namespace(buf, NS_CUR, 0, -1)
  for i, item in ipairs(self.hist_items) do
    if item.commit and item.commit.hash == self.current_commit and item.k == "commit" then
      pcall(api.nvim_buf_set_extmark, buf, NS_CUR, i - 1, 0, { line_hl_group = "DifferPanelCurrent", priority = 10 })
    end
  end
end

function Panel:_history_item()
  local line = api.nvim_win_get_cursor(self.app.side_win)[1]
  return self.hist_items[line], line
end

function Panel:_show_commit(item)
  if item and item.commit then
    self.current_commit = item.commit.hash
    self:_mark_commit()
    self.app:show_commit(item.commit, item.file and item.file.path)
  end
end

function Panel:_toggle_commit_files(item)
  local c = item and item.commit
  if not c then
    return
  end
  if self.expanded[c.hash] then
    self.expanded[c.hash] = nil
    self:render_history()
    return
  end
  local base = c.parents[1] or git.empty_tree(self.app.root)
  git.diff_files(self.app.root, base, c.hash, function(files)
    if self.app.closed then
      return
    end
    self.expanded[c.hash] = files
    self:render_history()
  end)
end

function Panel:_history_keys()
  local buf, keys, app = self.history_buf, config.options.keys.history, self.app
  local function m(lhs, fn, desc)
    self:_map(buf, lhs, fn, desc)
  end
  m(keys.activate, function() self:_show_commit(self:_history_item()) end, "show commit")
  m(keys.toggle_files, function() self:_toggle_commit_files(self:_history_item()) end, "list commit's files")
  m(keys.yank, function()
    local item = self:_history_item()
    if item and item.commit then
      vim.fn.setreg(vim.v.register, item.commit.hash)
      ops.notify("Yanked " .. item.commit.short)
    end
  end, "yank hash")
  m(keys.toggle_all, function()
    self.hist_all = not self.hist_all
    self:reset_history()
    self:load_history()
    ops.notify(self.hist_all and "History: all branches" or "History: current branch")
  end, "toggle all branches")
  m(keys.help, function() app:help() end, "help")
  m(keys.next_tab, function() app:switch_tab("changes") end, "Changes tab")
  m(keys.prev_tab, function() app:switch_tab("changes") end, "Changes tab")
  vim.keymap.set("n", "<LeftRelease>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid == app.side_win and vim.fn.mode() == "n" then
      self:_show_commit(self.hist_items[pos.line])
    end
  end, { buffer = buf, silent = true })
  app:common_keymaps(buf)
end

function Panel:_debounce(name, ms, fn)
  if not self[name] then
    self[name] = vim.uv.new_timer()
  end
  self[name]:stop()
  self[name]:start(ms, 0, vim.schedule_wrap(fn))
end

function Panel:_autocmds()
  local app = self.app
  self.group = api.nvim_create_augroup("differ.panel", { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = self.group, buffer = self.changes_buf,
    callback = function()
      if not config.options.follow or api.nvim_get_current_win() ~= app.side_win then
        return
      end
      self:_debounce("follow_timer", 60, function()
        if api.nvim_get_current_win() ~= app.side_win or self.tab ~= "changes" then
          return
        end
        local item = self:item_at_cursor()
        if item and item.k == "file" and item.file.path ~= self.current_path then
          app:show_file(item.file.path)
        end
      end)
    end,
  })
  api.nvim_create_autocmd("CursorMoved", {
    group = self.group, buffer = self.history_buf,
    callback = function()
      if api.nvim_get_current_win() ~= app.side_win then
        return
      end
      local line = api.nvim_win_get_cursor(app.side_win)[1]
      if #self.hist_items - line < 60 then
        self:load_history()
      end
      if config.options.follow then
        self:_debounce("hist_timer", 120, function()
          if api.nvim_get_current_win() ~= app.side_win or self.tab ~= "history" then
            return
          end
          local item = self:_history_item()
          if item and item.commit and item.commit.hash ~= self.current_commit then
            self:_show_commit(item)
          end
        end)
      end
    end,
  })
end

-- Commit box ---------------------------------------------------------------

function Panel:_make_commit_buf()
  local buf = api.nvim_create_buf(false, true)
  pcall(api.nvim_buf_set_name, buf, "differ://commit")
  local bo = vim.bo[buf]
  bo.buftype = "acwrite"
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.buflisted = false
  bo.filetype = "gitcommit"
  bo.textwidth = 0
  local keys = config.options.keys.commit
  for _, lhs in ipairs({ keys.submit, keys.submit_alt }) do
    if lhs then
      vim.keymap.set({ "n", "i" }, lhs, function() self:commit() end, { buffer = buf, silent = true, desc = "Differ: commit" })
    end
  end
  local toggle = config.options.keys.common.toggle_tab
  if toggle then
    vim.keymap.set("n", toggle, function() self.app:toggle_tab() end, { buffer = buf, silent = true, desc = "Differ: switch Changes / History" })
  end
  -- A global `:bnext` style H/L would only error here, as this window is fixed.
  local tab_keys = config.options.keys.changes
  for _, lhs in ipairs({ tab_keys.next_tab, tab_keys.prev_tab }) do
    if lhs then
      vim.keymap.set("n", lhs, function() self.app:switch_tab("history") end, { buffer = buf, silent = true, desc = "Differ: History tab" })
    end
  end
  if keys.amend then
    vim.keymap.set({ "n", "i" }, keys.amend, function() self:toggle_amend() end, { buffer = buf, silent = true, desc = "Differ: toggle amend" })
  end
  local group = api.nvim_create_augroup("differ.commit", { clear = true })
  api.nvim_create_autocmd("BufWriteCmd", {
    group = group, buffer = buf,
    callback = function() self:commit() end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter", "BufLeave" }, {
    group = group, buffer = buf,
    callback = function() self:_placeholder() end,
  })
  vim.schedule(function()
    if api.nvim_buf_is_valid(buf) then
      self:_placeholder()
    end
  end)
  return buf
end

function Panel:_placeholder()
  local buf = self.commit_buf
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    local text = self.amend and "Amend message" or "Enter commit message"
    api.nvim_buf_set_extmark(buf, NS, 0, 0, {
      virt_text = { { text, "DifferPlaceholder" } },
      virt_text_pos = "overlay",
    })
  end
  vim.bo[buf].modified = false
end

function Panel:update_commit_bar()
  local win = self.app.commit_win
  if not win or not api.nvim_win_is_valid(win) or not self.status then
    return
  end
  local s = self.status
  local icons = config.options.icons
  local keys = config.options.keys.commit
  local parts = { "%#DifferBarDim# ", icons.branch, " ", "%#DifferBarTitle#", (s.branch:gsub("%%", "%%%%")) }
  if s.upstream then
    if s.behind > 0 then
      parts[#parts + 1] = "%#DifferBarDim# ↓" .. s.behind
    end
    if s.ahead > 0 then
      parts[#parts + 1] = "%#DifferBarDim# ↑" .. s.ahead
    end
  end
  if self.amend then
    parts[#parts + 1] = "%#DifferBarFile# amend"
  end
  parts[#parts + 1] = "%#DifferBar#%="
  local function btn(fn, text, hl)
    return ("%%#%s#%%@v:lua.DifferClick.%s@ %s %%X%%#DifferBar# "):format(hl, fn, text)
  end
  if s.behind > 0 then
    parts[#parts + 1] = btn("pull", "Pull", "DifferBarBtn")
  end
  if s.ahead > 0 then
    parts[#parts + 1] = btn("push", "Push", "DifferBarBtn")
  end
  local hint = (keys.submit or ""):gsub("<C%-(%a)>", "⌃%1")
  parts[#parts + 1] = btn("submit", "Commit " .. hint, "DifferBarBtnPrimary")
  vim.wo[win].winbar = table.concat(parts)
end

function Panel:toggle_amend()
  self.amend = not self.amend
  local buf = self.commit_buf
  local app = self.app
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local empty = #lines == 1 and lines[1] == ""
  if self.amend and empty then
    local ok, out = git.sync(app.root, { "log", "-1", "--format=%B" })
    if ok then
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(vim.trim(out), "\n", { plain = true }))
    end
  end
  self:_placeholder()
  self:update_commit_bar()
end

function Panel:commit()
  local buf = self.commit_buf
  local app = self.app
  local message = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  if message == "" then
    ops.notify("Enter a commit message first", vim.log.levels.WARN)
    return app:focus_commit()
  end
  if self.committing then
    return
  end
  local staged = false
  for _, f in ipairs(self.status and self.status.files or {}) do
    if f.kind ~= "untracked" and f.x ~= "." then
      staged = true
      break
    end
  end
  if not staged and not self.amend then
    if vim.fn.confirm("Nothing is staged. Stage everything and commit?", "&Stage all\n&Cancel", 2) ~= 1 then
      return
    end
    git.sync(app.root, { "add", "-A" })
  end
  self.committing = true
  if vim.fn.mode():sub(1, 1) == "i" then
    vim.cmd.stopinsert()
  end
  ops.commit(app.root, message, { amend = self.amend }, function(ok)
    self.committing = false
    if app.closed then
      return -- the view was closed while git ran; the commit itself still happened
    end
    if ok then
      self.amend = false
      api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
      self:_placeholder()
      self:reset_history()
      if self.tab == "history" then
        self:load_history()
      end
    end
    app:refresh()
  end)
end

return M
