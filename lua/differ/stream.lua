-- The "stream": one buffer showing the diff of many files, top to bottom.
--
-- Every buffer line is described by an entry in `self.rows`, kept in step with
-- the text through nvim_buf_attach. Added and context lines are real file lines
-- and can be edited; deleted lines and headers are protected. `:w` works out
-- each edited file's new text from the rows and writes it. Highlights, line
-- numbers and stage bars are all computed from rows at draw time, so they can't
-- drift while you type.
--
-- Row kinds:
--   header, blank, sep, note, info  read-only chrome
--   del                             old line (read-only)
--   ctx, add, edit                  worktree lines (editable; edit = typed by you)
local M = {}

local api = vim.api
local git = require("differ.git")
local diff = require("differ.diff")
local syntax = require("differ.syntax")
local config = require("differ.config")
local ops = require("differ.ops")

local NS = api.nvim_create_namespace("differ.stream")
local NS_HINT = api.nvim_create_namespace("differ.stream.hint")

local by_buf = {}
local Stream = {}
Stream.__index = Stream

local EDITABLE = { ctx = true, add = true, edit = true }

local function total_changes(file)
  return (file.adds or 0) + (file.dels or 0)
end

local function count_lines(root, path)
  local text = git.read_work(root, path)
  if not text then
    return 0, false
  end
  if diff.is_binary(text) then
    return 0, true
  end
  local _, n = text:gsub("\n", "")
  if #text > 0 and text:sub(-1) ~= "\n" then
    n = n + 1
  end
  return n, false
end
M.count_lines = count_lines

-- Construction -------------------------------------------------------------

--- opts.kind is "worktree" (editable, stageable) or "commit" (read-only).
function M.new(app, opts)
  local self = setmetatable({
    app = app,
    root = app.root,
    kind = opts.kind,
    base = opts.base,
    rev = opts.rev,
    title = opts.title,
    info = opts.info,
    files = {},
    by_path = {},
    rows = {},
    shadow = {},
    dirty = {},
    tx = {},
    syntax = {},
  }, Stream)
  local buf = api.nvim_create_buf(false, true)
  self.buf = buf
  by_buf[buf] = self
  local name = "differ://" .. (opts.rev or "changes")
  pcall(api.nvim_buf_set_name, buf, name)
  local bo = vim.bo[buf]
  bo.buftype = self.kind == "worktree" and "acwrite" or "nofile"
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.buflisted = false
  bo.modifiable = false
  bo.filetype = "differ"
  vim.b[buf].completion = false
  pcall(function()
    require("ibl").setup_buffer(buf, { enabled = false })
  end)
  pcall(function()
    require("illuminate.engine").stop_buf(buf)
  end)

  api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, last, new_last)
      return self:_on_lines(first, last, new_last)
    end,
  })
  self:_autocmds()
  self:_keymaps()
  return self
end

function Stream:destroy()
  by_buf[self.buf] = nil
  if self.reindex_timer then
    self.reindex_timer:stop()
    self.reindex_timer:close()
    self.reindex_timer = nil
  end
  if api.nvim_buf_is_valid(self.buf) then
    pcall(api.nvim_buf_delete, self.buf, { force = true })
  end
end

function Stream:is_dirty()
  return next(self.dirty) ~= nil
end

function Stream:win()
  local win = self.app.main_win
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == self.buf then
    return win
  end
end

--- Window options for showing a stream in `win`.
function Stream:attach_window(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.colorcolumn = ""
  wo.spell = false
  wo.list = false
  wo.wrap = self.wrap or false
  wo.cursorline = true
  wo.diff = false
  wo.scrollbind = false
  wo.cursorbind = false
  wo.foldmethod = "manual"
  wo.foldenable = true
  wo.foldminlines = 0
  wo.foldtext = "v:lua.require'differ.stream'.foldtext()"
  wo.fillchars = "fold: ,eob: "
  wo.statuscolumn = "%!v:lua.require'differ.stream'.statuscolumn()"
  wo.winhighlight = ""
  self:_apply_folds()
  self:update_winbar()
end

-- Loading ------------------------------------------------------------------

local function fingerprint(root, file)
  local stat = file.kind ~= "commit" and vim.uv.fs_stat(root .. "/" .. file.path) or nil
  return table.concat({
    file.x, file.y, file.head_oid or "", file.index_oid or "",
    stat and stat.size or "", stat and stat.mtime.sec or "", stat and stat.mtime.nsec or "",
  }, ":")
end

local function stage_of(file)
  if file.kind == "untracked" or file.kind == "conflict" then
    return "none"
  end
  if file.y == "." then
    return "full"
  end
  return file.x == "." and "none" or "partial"
end
M.stage_of = stage_of

--- Replace the file list, reusing loaded data for files that didn't change.
function Stream:set_files(files, done)
  -- Rows point at these file objects, so nothing is swapped while edits are
  -- pending; the view catches up after :w.
  if self:is_dirty() then
    self.stale = true
    if done then
      done()
    end
    return
  end
  local old = self.by_path
  local by_path, list = {}, {}
  for i, file in ipairs(files) do
    file.fp = fingerprint(self.root, file)
    file.stage = stage_of(file)
    local prev = old[file.path]
    if prev and prev.fp == file.fp then
      -- Unchanged: keep the object rows already refer to. Refresh status fields.
      file.adds = file.adds or prev.adds
      file.dels = file.dels or prev.dels
      file.binary = file.binary or prev.binary
      for k, v in pairs(file) do
        prev[k] = v
      end
      file = prev
    elseif prev then
      file.collapsed, file.shown, file.want = prev.collapsed, prev.shown, prev.want
    end
    file.ts = file.ts or {}
    by_path[file.path] = file
    list[i] = file
  end
  files = list
  self.files, self.by_path = files, by_path

  local signature = {}
  for _, file in ipairs(files) do
    signature[#signature + 1] = file.path .. "|" .. file.fp
  end
  signature = table.concat(signature, "\n")
  local unchanged = signature == self.signature

  self:_select_eager()
  self:load(self:_pending(), function()
    self.signature = signature
    if not unchanged or #self.rows == 0 then
      self:render()
    end
    if done then
      done()
    end
  end)
end

function Stream:_select_eager()
  local budget = config.options.load_budget
  local limit = config.options.max_file_lines
  for _, file in ipairs(self.files) do
    if file.kind == "untracked" and not file.adds then
      local stat = vim.uv.fs_stat(self.root .. "/" .. file.path)
      -- Don't read huge files just to count their lines.
      if stat and stat.size < 2 * 1024 * 1024 then
        file.adds, file.binary = count_lines(self.root, file.path)
        file.dels = 0
      else
        file.adds, file.dels = 0, 0
        file.huge = true
      end
    end
    local n = total_changes(file)
    file.too_large = n > limit or file.huge == true
    if not file.loaded and not file.too_large then
      if budget - n >= 0 then
        file.want = true
      end
    end
    if file.want or file.loaded then
      budget = budget - n
    end
  end
end

function Stream:_pending()
  local out = {}
  for _, file in ipairs(self.files) do
    if file.want and not file.loaded then
      out[#out + 1] = file
    end
  end
  return out
end

function Stream:_prepare(file, head, index, work)
  file.head, file.index, file.work = head, index, work
  file.loaded = true
  file.want = true
  if diff.is_binary(head) or diff.is_binary(work) or (file.binary and file.kind ~= "untracked") then
    file.binary_body = true
    file.hunks = {}
    file.H, file.W = {}, {}
    return
  end
  file.binary_body = false
  file.H, file.W = diff.split(head), diff.split(work)
  file.eol = (file.W[1] or file.H[1] or ""):sub(-2) == "\r\n" and "\r\n" or "\n"
  file.hunks = diff.hunks(head, work)
  if self.kind == "worktree" then
    local hi, iw = diff.hunks(head, index), diff.hunks(index, work)
    for _, h in ipairs(file.hunks) do
      h.state = diff.stage_state(h, hi, iw)
    end
  end
end

--- Fetch contents for the given files. `cb` runs when they're ready.
function Stream:load(files, cb)
  if #files == 0 then
    return cb()
  end
  local specs = {}
  for _, f in ipairs(files) do
    local old = f.old_path or f.path
    if self.kind == "worktree" then
      specs[#specs + 1] = "HEAD:" .. old
      specs[#specs + 1] = ":" .. f.path
    else
      specs[#specs + 1] = self.base .. ":" .. old
      specs[#specs + 1] = self.rev .. ":" .. f.path
    end
  end
  git.cat_file(self.root, specs, function(objs)
    if not by_buf[self.buf] then
      return -- this stream was closed while git ran
    end
    for i, f in ipairs(files) do
      local a, b = objs[2 * i - 1] or "", objs[2 * i] or ""
      if self.kind == "worktree" then
        self:_prepare(f, a, b, git.read_work(self.root, f.path) or "")
      else
        self:_prepare(f, a, b, b)
      end
    end
    cb()
  end)
end

-- Rendering ----------------------------------------------------------------

local function emit_header(self, file, lines, rows)
  local icons = config.options.icons
  local chevron = file.loaded and icons.expanded or icons.collapsed
  local check = ""
  if self.kind == "worktree" then
    local mark = file.stage == "full" and icons.checked or (file.stage == "partial" and icons.partial or icons.unchecked)
    check = mark .. " "
  end
  local dir = vim.fs.dirname(file.path)
  local name = vim.fs.basename(file.path)
  if file.old_path then
    name = file.old_path .. " → " .. name
    dir = "."
  end
  local prefix = "  " .. chevron .. " " .. check
  local text = prefix .. name .. (dir ~= "." and ("  " .. dir .. "/") or "")
  lines[#lines + 1] = text
  rows[#rows + 1] = {
    k = "header", f = file,
    name_s = #prefix, name_e = #prefix + #name, chev_e = #("  " .. chevron), check_e = #prefix,
  }
end

local function emit_body(self, file, lines, rows)
  if not file.loaded then
    return
  end
  if file.binary_body then
    lines[#lines + 1] = "    Binary file"
    rows[#rows + 1] = { k = "note", f = file }
    return
  end
  if #file.hunks == 0 then
    lines[#lines + 1] = "    No content changes"
    rows[#rows + 1] = { k = "note", f = file }
    return
  end
  local W, H = file.W, file.H
  local excerpts = diff.excerpts(file.hunks, #W, config.options.context, file.shown)
  file.excerpts = excerpts
  local function sep(s, e)
    if e >= s then
      local n = e - s + 1
      lines[#lines + 1] = ("    ⋯ %d unchanged line%s"):format(n, n == 1 and "" or "s")
      rows[#rows + 1] = { k = "sep", f = file, gap = { s = s, e = e } }
    end
  end
  local hi = 1
  local hunks = file.hunks
  local prev_end = 0
  for _, x in ipairs(excerpts) do
    sep(prev_end + 1, x.s - 1)
    local function flush_at(n)
      while hunks[hi] and hunks[hi].bs == n do
        local h = hunks[hi]
        for o = h.as, h.as + h.ac - 1 do
          lines[#lines + 1] = diff.strip(H[o])
          rows[#rows + 1] = { k = "del", f = file, o = o, h = h, x = x }
        end
        if h.bc > 0 then
          for w = h.bs, h.bs + h.bc - 1 do
            lines[#lines + 1] = diff.strip(W[w])
            rows[#rows + 1] = { k = "add", f = file, w = w, n = w, h = h, x = x }
          end
        end
        hi = hi + 1
      end
    end
    local n = x.s
    while n <= x.e do
      flush_at(n)
      if hunks[hi - 1] and n < hunks[hi - 1].bs + hunks[hi - 1].bc then
        n = hunks[hi - 1].bs + hunks[hi - 1].bc
      else
        lines[#lines + 1] = diff.strip(W[n])
        rows[#rows + 1] = { k = "ctx", f = file, w = n, n = n, x = x }
        n = n + 1
      end
    end
    flush_at(x.e + 1)
    prev_end = x.e
  end
  sep(prev_end + 1, #W)
end

local function emit_file(self, file, lines, rows)
  emit_header(self, file, lines, rows)
  emit_body(self, file, lines, rows)
end

function Stream:_build()
  local lines, rows = {}, {}
  if self.info then
    for _, item in ipairs(self.info) do
      lines[#lines + 1] = item.text
      rows[#rows + 1] = { k = "info", hl = item.hl }
    end
  end
  if #self.files == 0 then
    lines[#lines + 1] = ""
    rows[#rows + 1] = { k = "blank" }
    lines[#lines + 1] = self.kind == "worktree" and "    Nothing to review: the working tree is clean." or "    This commit changes no files."
    rows[#rows + 1] = { k = "note" }
  end
  for i, file in ipairs(self.files) do
    if i > 1 or self.info then
      lines[#lines + 1] = ""
      rows[#rows + 1] = { k = "blank" }
    end
    emit_file(self, file, lines, rows)
  end
  return lines, rows
end

--- Change the buffer ourselves: no row tracking, and no undo across this point,
--- because undo must never restore text the rows no longer describe.
function Stream:_write(first, last, lines)
  local buf = self.buf
  self.internal = true
  local bo = vim.bo[buf]
  bo.modifiable = true
  local keep_modified = self:is_dirty()
  local ul = bo.undolevels
  bo.undolevels = -1
  api.nvim_buf_set_lines(buf, first, last, false, lines)
  bo.undolevels = ul
  bo.modified = keep_modified
  self.internal = false
  self:_sync_modifiable()
end

local function anchor_of(self, win)
  if not win then
    return nil
  end
  local cur = api.nvim_win_get_cursor(win)
  local r = self.rows[cur[1]]
  local top = vim.fn.line("w0", win)
  return { r = r, line = cur[1], col = cur[2], off = cur[1] - top }
end

local function restore_anchor(self, win, a)
  if not win or not a then
    return
  end
  local target
  local r = a.r
  if r and r.f then
    local header
    for i, o in ipairs(self.rows) do
      if o.f and o.f.path == r.f.path then
        if o.k == "header" then
          header = i
        end
        if o.k == r.k and o.w == r.w and o.o == r.o then
          target = i
          break
        end
      end
    end
    target = target or header
  end
  target = math.min(target or a.line, math.max(#self.rows, 1))
  pcall(api.nvim_win_set_cursor, win, { target, a.col })
  pcall(api.nvim_win_call, win, function()
    vim.fn.winrestview({ topline = math.max(1, target - a.off) })
  end)
end

function Stream:render()
  local win = self:win()
  local anchor = anchor_of(self, win)
  local lines, rows = self:_build()
  self:_write(0, -1, lines)
  self.rows, self.shadow = rows, lines
  self.stale = false
  self:_update_width()
  self:_apply_folds()
  restore_anchor(self, win, anchor)
  self:_on_cursor()
  self:update_winbar()
end

--- Re-render one file in place, leaving edits to other files untouched.
function Stream:_replace_file(file)
  local first, last = self:file_range(file)
  if not first then
    return self:render()
  end
  local lines, rows = {}, {}
  emit_file(self, file, lines, rows)
  local win = self:win()
  local anchor = anchor_of(self, win)
  self:_write(first - 1, last, lines)
  self:_splice(first, last, rows, lines)
  self:_update_width()
  self:_apply_folds()
  if anchor and anchor.line > first then
    restore_anchor(self, win, anchor)
  end
  self:_on_cursor()
end

function Stream:_update_width()
  local max = 0
  for _, file in ipairs(self.files) do
    if file.W then
      max = math.max(max, #file.W)
    end
  end
  self.num_width = math.max(#tostring(max), 3)
end

--- Splice new rows and shadow text over lines [first, last] (1-based inclusive).
function Stream:_splice(first, last, rows, lines)
  local function splice(t, new)
    local removed = last - first + 1
    local delta = #new - removed
    if delta ~= 0 then
      table.move(t, last + 1, #t, last + 1 + delta)
      if delta < 0 then
        for i = #t, #t + delta + 1, -1 do
          t[i] = nil
        end
      end
    end
    for i, v in ipairs(new) do
      t[first + i - 1] = v
    end
  end
  splice(self.rows, rows)
  splice(self.shadow, lines)
end

--- First and last row of a file's section (excluding the blank before the next).
function Stream:file_range(file)
  local first
  for i, r in ipairs(self.rows) do
    if first then
      if r.k == "blank" or r.k == "header" then
        return first, i - 1
      end
    elseif r.k == "header" and r.f == file then
      first = i
    end
  end
  if first then
    return first, #self.rows
  end
end

function Stream:_apply_folds()
  local win = self:win()
  if not win then
    return
  end
  api.nvim_win_call(win, function()
    pcall(vim.cmd, "silent! normal! zE")
    for _, file in ipairs(self.files) do
      if file.collapsed and file.loaded then
        local first, last = self:file_range(file)
        if first and last > first then
          vim.cmd(("silent! %d,%dfold"):format(first, last))
          vim.cmd(("silent! %dfoldclose"):format(first))
        end
      end
    end
  end)
end

-- Edit tracking ------------------------------------------------------------

function Stream:_on_lines(first, last, new_last)
  if self.internal or by_buf[self.buf] == nil then
    return
  end
  local count = new_last - first
  local removed_rows, removed_lines = {}, {}
  local violation = false
  for i = first + 1, last do
    local r = self.rows[i]
    removed_rows[#removed_rows + 1] = r
    removed_lines[#removed_lines + 1] = self.shadow[i]
    if r and not EDITABLE[r.k] then
      violation = true
    end
  end
  local prev, nxt = self.rows[first], self.rows[last + 1]
  local anchor = removed_rows[1]
  if not anchor or not EDITABLE[anchor.k] then
    anchor = (prev and EDITABLE[prev.k] and prev) or (nxt and EDITABLE[nxt.k] and nxt) or nil
  end
  if count > 0 and not anchor then
    violation = true
  end
  local new_lines = api.nvim_buf_get_lines(self.buf, first, new_last, false)
  local new_rows = {}
  for i = 1, count do
    local old = removed_rows[i]
    if old and EDITABLE[old.k] and removed_lines[i] == new_lines[i] then
      new_rows[i] = old -- rewritten but identical (e.g. undo)
    else
      local a = (old and EDITABLE[old.k] and old) or anchor
      new_rows[i] = { k = "edit", f = a and a.f, x = a and a.x }
    end
  end
  self:_splice(first + 1, last, new_rows, new_lines)
  self.tx[#self.tx + 1] = { first = first, count = count, lines = removed_lines, rows = removed_rows }
  if violation then
    self.violated = true
  else
    for _, r in ipairs(removed_rows) do
      if r.f then
        self.dirty[r.f] = true
      end
    end
    for _, r in ipairs(new_rows) do
      if r.f then
        self.dirty[r.f] = true
      end
    end
  end
  if not self.tx_scheduled then
    self.tx_scheduled = true
    vim.schedule(function()
      self:_end_tx()
    end)
  end
end

--- Runs once per batch of changes. Rolls the whole batch back if any of it
--- touched protected lines (e.g. `dG` starting on an editable line).
function Stream:_end_tx()
  self.tx_scheduled = false
  local tx = self.tx
  self.tx = {}
  if self.violated then
    self.violated = false
    if not api.nvim_buf_is_valid(self.buf) then
      return
    end
    self.internal = true
    for i = #tx, 1, -1 do
      local c = tx[i]
      pcall(vim.cmd, "silent! undojoin")
      api.nvim_buf_set_lines(self.buf, c.first, c.first + c.count, false, c.lines)
      self:_splice(c.first + 1, c.first + c.count, c.rows, c.lines)
    end
    self.internal = false
    self:_apply_folds()
    self:_sync_modifiable()
    ops.notify("Deleted lines and headers can't be edited; change undone", vim.log.levels.WARN)
  end
  self:_schedule_reindex()
end

function Stream:_schedule_reindex()
  if not self.reindex_timer then
    self.reindex_timer = vim.uv.new_timer()
  end
  self.reindex_timer:stop()
  self.reindex_timer:start(120, 0, vim.schedule_wrap(function()
    if by_buf[self.buf] then
      self:_reindex()
    end
  end))
end

--- The file text a file's rows currently describe, numbering rows on the way.
function Stream:reconstruct(file)
  local first, last = self:file_range(file)
  local W = file.W
  local eol = file.eol or "\n"
  -- Rows by excerpt. An excerpt with no rows left had all its lines deleted.
  local by_excerpt = {}
  for i = first or 1, first and last or 0 do
    local r = self.rows[i]
    if EDITABLE[r.k] and r.x then
      local list = by_excerpt[r.x]
      if not list then
        list = {}
        by_excerpt[r.x] = list
      end
      list[#list + 1] = i
    end
  end
  local out = {}
  local pos = 1
  for _, x in ipairs(file.excerpts or {}) do
    for n = pos, x.s - 1 do
      out[#out + 1] = W[n]
    end
    for _, i in ipairs(by_excerpt[x] or {}) do
      local r = self.rows[i]
      if r.w and self.shadow[i] == diff.strip(W[r.w] or "") then
        out[#out + 1] = W[r.w]
      else
        out[#out + 1] = self.shadow[i] .. eol
      end
      r.n = #out
    end
    pos = x.e + 1
  end
  for n = pos, #W do
    out[#out + 1] = W[n]
  end
  -- Keep the original's final-newline state, whichever line is now last.
  for i = 1, #out - 1 do
    if out[i]:sub(-1) ~= "\n" then
      out[i] = out[i] .. eol
    end
  end
  if #out > 0 and file.work ~= "" and file.work:sub(-1) ~= "\n" then
    out[#out] = diff.strip(out[#out])
  end
  return table.concat(out)
end

function Stream:_reindex()
  for file in pairs(self.dirty) do
    local text = self:reconstruct(file)
    file.edited = text
    if text == file.work then
      self.dirty[file] = nil
      file.edited = nil
    end
  end
  if not self:is_dirty() then
    if vim.bo[self.buf].modified then
      vim.bo[self.buf].modified = false
    end
    if self.stale then
      self.stale = false
      self.signature = nil
      self.app:refresh()
    end
  end
  self:update_winbar()
  local win = self:win()
  if win then
    api.nvim__redraw({ win = win, valid = false })
  end
end

--- `:w`: write every edited file back to disk.
function Stream:save()
  self:_reindex()
  local written, skipped = 0, 0
  for file in pairs(self.dirty) do
    local text = self:reconstruct(file)
    local disk = git.read_work(self.root, file.path) or ""
    local buf = ops.find_buffer(self.root, file.path)
    local loaded = buf ~= nil
    if disk ~= file.work then
      skipped = skipped + 1
      ops.notify(file.path .. " changed on disk since it was shown; not overwriting it", vim.log.levels.WARN)
    elseif loaded and vim.bo[buf].modified then
      skipped = skipped + 1
      ops.notify(file.path .. " has unsaved changes in another buffer; not overwriting it", vim.log.levels.WARN)
    elseif loaded then
      -- Go through the open buffer so its LSP, formatter and gitsigns stay in step.
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(diff.strip, diff.split(text)))
      api.nvim_buf_call(buf, function()
        vim.cmd("silent! keepalt update")
      end)
      written = written + 1
      self.dirty[file] = nil
    else
      local ok, err = ops.write_work(self.root, file, text)
      if ok then
        written = written + 1
        self.dirty[file] = nil
      else
        skipped = skipped + 1
        ops.notify("Could not write " .. file.path .. ": " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end
  if not self:is_dirty() then
    vim.bo[self.buf].modified = false
  end
  if written > 0 then
    ops.notify(("Wrote %d file%s"):format(written, written == 1 and "" or "s"))
  end
  self.signature = nil
  self.app:refresh()
  return skipped == 0
end

-- Cursor -------------------------------------------------------------------

function Stream:_sync_modifiable()
  local buf = self.buf
  local win = self:win()
  local editable = false
  if self.kind == "worktree" and win then
    local r = self.rows[api.nvim_win_get_cursor(win)[1]]
    editable = r ~= nil and EDITABLE[r.k] == true
  end
  if vim.bo[buf].modifiable ~= editable then
    vim.bo[buf].modifiable = editable
  end
end

function Stream:row_at_cursor()
  local win = self:win() or api.nvim_get_current_win()
  local line = api.nvim_win_get_cursor(win)[1]
  return self.rows[line], line
end

local function hunk_first_row(self, line, h)
  local i = line
  while i > 1 and self.rows[i - 1] and self.rows[i - 1].h == h do
    i = i - 1
  end
  return i
end

function Stream:_on_cursor()
  local win = self:win()
  if not win then
    return
  end
  self:_sync_modifiable()
  local r, line = self:row_at_cursor()
  api.nvim_buf_clear_namespace(self.buf, NS_HINT, 0, -1)
  self.hint = nil
  if self.kind == "worktree" and r and r.h and not self:is_dirty() then
    local first = hunk_first_row(self, line, r.h)
    local keys = config.options.keys.stream
    local stage_label = r.h.state == "full" and " Unstage " or " Stage "
    local text1 = (keys.stage or "") .. stage_label
    local text2 = (keys.restore or "") .. " Restore "
    self.hint = { line = first, stage_w = vim.fn.strdisplaywidth(text1), restore_w = vim.fn.strdisplaywidth(text2) + 1 }
    pcall(api.nvim_buf_set_extmark, self.buf, NS_HINT, first - 1, 0, {
      virt_text = { { " " .. text1, "DifferHint" }, { " ", "Normal" }, { " " .. text2, "DifferHintAlt" } },
      virt_text_pos = "right_align",
      priority = 500,
    })
  end
  local path = r and r.f and r.f.path
  if path ~= self.current_path then
    self.current_path = path
    self.app:on_stream_file(self, path)
  end
end

function Stream:update_winbar()
  local win = self:win()
  if not win then
    return
  end
  local adds, dels = 0, 0
  for _, file in ipairs(self.files) do
    adds, dels = adds + (file.adds or 0), dels + (file.dels or 0)
  end
  local parts = { "%#DifferBarTitle# ", (self.title or ""):gsub("%%", "%%%%"), " " }
  parts[#parts + 1] = ("%%#DifferBarAdd#+%d %%#DifferBarDel#−%d "):format(adds, dels)
  if self:is_dirty() then
    local n = 0
    for _ in pairs(self.dirty) do
      n = n + 1
    end
    parts[#parts + 1] = ("%%#DifferBarFile# ● %d unsaved (:w) "):format(n)
  end
  -- Sticky file: the file at the top of the window.
  local top = vim.fn.line("w0", win)
  local r = self.rows[top]
  local file = r and r.f
  if file then
    local escaped = file.path:gsub("%%", "%%%%")
    parts[#parts + 1] = "%#DifferBarDim#│ %#DifferBarFile#" .. escaped .. " "
  end
  parts[#parts + 1] = "%#DifferBar#%="
  local btn = function(fn, text, hl)
    return ("%%#%s#%%@v:lua.DifferClick.%s@ %s %%X%%#DifferBar# "):format(hl, fn, text)
  end
  if self.kind == "worktree" then
    parts[#parts + 1] = btn("stage_all", "Stage All", "DifferBarBtn")
  end
  parts[#parts + 1] = btn("toggle_mode", "Split", "DifferBarBtn")
  if self.kind == "worktree" then
    parts[#parts + 1] = btn("commit", "Commit", "DifferBarBtnPrimary")
  end
  vim.wo[win].winbar = table.concat(parts)
end

-- Actions ------------------------------------------------------------------

local function closed_fold(win, line)
  return api.nvim_win_call(win, function()
    return vim.fn.foldclosed(line) ~= -1
  end)
end

function Stream:_goto(line, top)
  local win = self:win()
  if not win then
    return
  end
  api.nvim_win_set_cursor(win, { line, 0 })
  api.nvim_win_call(win, function()
    vim.cmd("normal! " .. (top and "zt" or "zz"))
  end)
  self:_on_cursor()
end

function Stream:jump_hunk(dir)
  local win = self:win()
  local r, line = self:row_at_cursor()
  local current = r and r.h
  local i = line + dir
  while self.rows[i] do
    local o = self.rows[i]
    if o.h and o.h ~= current and not closed_fold(win, i) then
      if dir < 0 then
        i = hunk_first_row(self, i, o.h)
      end
      return self:_goto(i)
    end
    i = i + dir
  end
end

function Stream:jump_file(dir)
  local _, line = self:row_at_cursor()
  local i = line + dir
  while self.rows[i] do
    if self.rows[i].k == "header" then
      return self:_goto(i, true)
    end
    i = i + dir
  end
end

--- Show a file: scroll its header to the top, loading it if needed.
function Stream:jump_to(path, opts)
  opts = opts or {}
  local file = self.by_path[path]
  if not file then
    return
  end
  local function go()
    for i, r in ipairs(self.rows) do
      if r.k == "header" and r.f == file then
        return self:_goto(i, true)
      end
    end
  end
  if not file.loaded and (not file.too_large or opts.force) then
    self:load_file(file, go)
  else
    go()
  end
end

function Stream:load_file(file, cb)
  file.want = true
  self:load({ file }, function()
    self:_replace_file(file)
    if cb then
      cb()
    end
  end)
end

function Stream:toggle_fold()
  local r = self:row_at_cursor()
  local file = r and r.f
  if not file then
    return
  end
  if not file.loaded then
    return self:load_file(file)
  end
  local win = self:win()
  file.collapsed = not file.collapsed
  self:_apply_folds()
  local first = self:file_range(file)
  if first and file.collapsed then
    api.nvim_win_set_cursor(win, { first, 0 })
  end
  self:_on_cursor()
end

function Stream:activate()
  local r, line = self:row_at_cursor()
  if not r or not r.f then
    return
  end
  local file = r.f
  if r.k == "sep" then
    if self.dirty[file] then
      return ops.notify("Save your edits to this file (:w) before expanding it", vim.log.levels.WARN)
    end
    local gap, step = r.gap, config.options.expand_step
    file.shown = file.shown or {}
    if gap.e - gap.s + 1 <= step * 2 then
      table.insert(file.shown, { s = gap.s, e = gap.e })
    else
      if gap.s > 1 then
        table.insert(file.shown, { s = gap.s, e = gap.s + step - 1 })
      end
      if gap.e < #file.W then
        table.insert(file.shown, { s = gap.e - step + 1, e = gap.e })
      end
    end
    self:_replace_file(file)
    pcall(api.nvim_win_set_cursor, self:win(), { line, 0 })
    return
  end
  if r.k == "header" and not file.loaded then
    return self:load_file(file)
  end
  local target = r.n
  if not target then
    -- Deleted line or header: go to the nearest worktree line after it.
    local i = line + 1
    while self.rows[i] and self.rows[i].f == file do
      if self.rows[i].n then
        target = self.rows[i].n
        break
      end
      i = i + 1
    end
  end
  self.app:open_file(file.path, target or 1)
end

local function selection_lines(self, a, b)
  local sel, any = { a = {}, b = {} }, false
  local hunk
  for i = math.min(a, b), math.max(a, b) do
    local r = self.rows[i]
    if r and r.k == "del" then
      sel.a[r.o], any = true, true
      hunk = hunk or r.h
    elseif r and r.k == "add" then
      sel.b[r.w], any = true, true
      hunk = hunk or r.h
    end
  end
  return any and sel or nil, hunk
end

--- The hunk under the cursor, or failing that the closest one in the same file.
function Stream:_nearest_hunk(line)
  local r = self.rows[line]
  if not r or not r.f then
    return nil
  end
  if r.h then
    return r.h
  end
  for dist = 1, #self.rows do
    local down, up = self.rows[line + dist], self.rows[line - dist]
    if down and down.f == r.f and down.h then
      return down.h
    end
    if up and up.f == r.f and up.h then
      return up.h
    end
    if (not down or down.f ~= r.f) and (not up or up.f ~= r.f) then
      return nil
    end
  end
end

function Stream:_guard_edits()
  if self:is_dirty() then
    ops.notify("You have unsaved edits; write them with :w first", vim.log.levels.WARN)
    return false
  end
  return true
end

function Stream:stage(visual_from)
  if self.kind ~= "worktree" or not self:_guard_edits() then
    return
  end
  local r, line = self:row_at_cursor()
  if not r or not r.f then
    return
  end
  if r.k == "header" or r.f.binary_body or r.f.kind == "conflict" then
    return self.app:toggle_files({ r.f })
  end
  local h, lines
  if visual_from then
    lines, h = selection_lines(self, visual_from, line)
    if not lines then
      return
    end
  else
    h = self:_nearest_hunk(line)
  end
  if h then
    ops.toggle_hunk(self.root, r.f, h, lines)
    self.app:refresh()
  end
end

function Stream:restore(visual_from)
  if self.kind ~= "worktree" or not self:_guard_edits() then
    return
  end
  local r, line = self:row_at_cursor()
  if not r or not r.f then
    return
  end
  if r.k == "header" or r.f.binary_body then
    if ops.discard_files(self.root, { r.f }) then
      self.app:refresh()
    end
    return
  end
  local h, lines
  if visual_from then
    lines, h = selection_lines(self, visual_from, line)
    if not lines then
      return
    end
  else
    h = self:_nearest_hunk(line)
  end
  if h and ops.restore_hunk(self.root, r.f, h, lines) then
    self.app:refresh()
  end
end

function Stream:_on_mouse()
  local pos = vim.fn.getmousepos()
  local win = self:win()
  if pos.winid ~= win or vim.fn.mode() ~= "n" then
    return
  end
  local r = self.rows[pos.line]
  if not r then
    return
  end
  local width = api.nvim_win_get_width(win)
  if r.k == "header" then
    local info = vim.fn.getwininfo(win)[1]
    local col = pos.wincol - info.textoff - 1
    if col < r.chev_e then
      self:toggle_fold()
    elseif col < r.check_e and self.kind == "worktree" then
      self:stage()
    end
  elseif r.k == "sep" then
    self:activate()
  elseif self.hint and pos.line == self.hint.line then
    local from_right = width - pos.wincol
    if from_right < self.hint.restore_w then
      self:restore()
    elseif from_right < self.hint.restore_w + self.hint.stage_w + 1 then
      self:stage()
    end
  end
end

function Stream:_keymaps()
  local buf = self.buf
  local keys = config.options.keys.stream
  local function map(lhs, fn, desc, mode)
    if lhs then
      vim.keymap.set(mode or "n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Differ: " .. desc })
    end
  end
  map(keys.stage, function() self:stage() end, "stage or unstage hunk")
  map(keys.stage, function()
    local from = vim.fn.line("v")
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    self:stage(from)
  end, "stage or unstage selected lines", "x")
  map(keys.restore, function() self:restore() end, "restore hunk to HEAD")
  map(keys.restore, function()
    local from = vim.fn.line("v")
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    self:restore(from)
  end, "restore selected lines to HEAD", "x")
  map(keys.next_hunk, function() self:jump_hunk(1) end, "next hunk")
  map(keys.prev_hunk, function() self:jump_hunk(-1) end, "previous hunk")
  map(keys.next_file, function() self:jump_file(1) end, "next file")
  map(keys.prev_file, function() self:jump_file(-1) end, "previous file")
  map(keys.next_file_alt, function() self:jump_file(1) end, "next file")
  map(keys.prev_file_alt, function() self:jump_file(-1) end, "previous file")
  map(keys.toggle_fold, function() self:toggle_fold() end, "collapse or expand file")
  map(keys.activate, function() self:activate() end, "open file / expand")
  map(keys.stage_all, function() self.app:stage_all() end, "stage all")
  map(keys.unstage_all, function() self.app:unstage_all() end, "unstage all")
  map(keys.toggle_wrap, function()
    self.wrap = not self.wrap
    local win = self:win()
    if win then
      vim.wo[win].wrap = self.wrap
    end
  end, "toggle line wrap")
  vim.keymap.set("n", "<LeftRelease>", function() self:_on_mouse() end, { buffer = buf, silent = true })
  self.app:common_keymaps(buf)
end

function Stream:_autocmds()
  local buf = self.buf
  local group = api.nvim_create_augroup("differ.stream." .. buf, { clear = true })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group, buffer = buf,
    callback = function() self:_on_cursor() end,
  })
  if self.kind == "worktree" then
    api.nvim_create_autocmd("BufWriteCmd", {
      group = group, buffer = buf,
      callback = function() self:save() end,
    })
  end
  api.nvim_create_autocmd("BufDelete", {
    group = group, buffer = buf,
    callback = function()
      by_buf[buf] = nil
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
  api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      if by_buf[buf] and self:win() then
        self:update_winbar()
        self:_load_visible()
      end
    end,
  })
end

--- Lazily load files as they scroll into view (not while edits are unsaved,
--- since loading resets undo history).
function Stream:_load_visible()
  if self:is_dirty() or self.loading then
    return
  end
  local win = self:win()
  local top, bottom = vim.fn.line("w0", win), vim.fn.line("w$", win)
  local wanted = {}
  for i = top, bottom do
    local r = self.rows[i]
    if r and r.k == "header" and not r.f.loaded and not r.f.too_large then
      r.f.want = true
      wanted[#wanted + 1] = r.f
    end
  end
  if #wanted == 0 then
    return
  end
  self.loading = true
  self:load(wanted, function()
    self.loading = false
    for _, file in ipairs(wanted) do
      self:_replace_file(file)
    end
  end)
end

-- Drawing ------------------------------------------------------------------

local LINE_HL = {
  add = { none = "DifferAddLine", partial = "DifferAddLine", full = "DifferAddLineStaged" },
  del = { none = "DifferDelLine", partial = "DifferDelLine", full = "DifferDelLineStaged" },
}

local function words_for(h, file)
  if h.words then
    return h.words
  end
  local old, new = {}, {}
  for o = h.as, h.as + h.ac - 1 do
    old[#old + 1] = diff.strip(file.H[o])
  end
  for w = h.bs, h.bs + h.bc - 1 do
    new[#new + 1] = diff.strip(file.W[w])
  end
  local a, b = diff.word_diff(old, new)
  h.words = { a = a, b = b }
  return h.words
end

local function mark(buf, row, col, opts)
  opts.ephemeral = true
  opts.strict = false
  pcall(api.nvim_buf_set_extmark, buf, NS, row, col, opts)
end

--- Whole-row background, drawn through to the window edge.
local function line_bg(buf, row, group)
  mark(buf, row, 0, { end_row = row + 1, end_col = 0, hl_group = group, hl_eol = true, priority = 90 })
end

local function draw_syntax(self, buf, row, r, text_len)
  local file = r.f
  local side, line, text
  if r.k == "del" then
    side, line, text = "head", r.o, file.head
  elseif r.n then
    side, line, text = "work", r.n, file.edited or file.work
  else
    return
  end
  local tokens = syntax.get(file.ts, side, file.path, text)[line]
  if not tokens then
    return
  end
  for _, t in ipairs(tokens) do
    local e = math.min(t[2] or text_len, text_len)
    if t[1] < e then
      -- Many themes dim comments too far to read on a tinted line.
      local hl = (t[4] and r.h) and "DifferCommentChanged" or t[3]
      mark(buf, row, t[1], { end_col = e, hl_group = hl, priority = 110 })
    end
  end
end

local function draw_row(self, buf, row, r)
  local k = r.k
  if k == "header" then
    local file = r.f
    line_bg(buf, row, "DifferHeader")
    local deleted = file.x == "D" or file.y == "D"
    mark(buf, row, r.name_s, { end_col = r.name_e, hl_group = deleted and "DifferHeaderDeleted" or "DifferHeaderName", priority = 120 })
    mark(buf, row, r.name_e, { end_col = #self.shadow[row + 1], hl_group = "DifferHeaderDir", priority = 120 })
    if self.kind == "worktree" then
      mark(buf, row, r.chev_e, { end_col = r.check_e, hl_group = file.stage == "none" and "DifferHeaderDim" or "DifferHeaderName", priority = 120 })
    end
    local stats = {}
    if file.too_large and not file.loaded then
      stats[#stats + 1] = { " Large: ⏎ to load  ", "DifferHeaderDim" }
    elseif not file.loaded then
      stats[#stats + 1] = { " loads on scroll  ", "DifferHeaderDim" }
    end
    if file.binary then
      stats[#stats + 1] = { "binary ", "DifferHeaderDim" }
    else
      stats[#stats + 1] = { "+" .. (file.adds or 0), "DifferAddText" }
      stats[#stats + 1] = { " −" .. (file.dels or 0) .. " ", "DifferDelText" }
    end
    mark(buf, row, 0, { virt_text = stats, virt_text_pos = "right_align", hl_mode = "combine", priority = 120 })
    return
  end
  if k == "sep" then
    mark(buf, row, 0, { end_row = row + 1, hl_group = "DifferSep", hl_eol = false, priority = 120 })
    return
  end
  if k == "note" then
    mark(buf, row, 0, { end_row = row + 1, hl_group = "DifferNote", priority = 120 })
    return
  end
  if k == "info" then
    mark(buf, row, 0, { end_row = row + 1, hl_group = r.hl or "DifferInfo", priority = 120 })
    return
  end
  if k == "blank" then
    return
  end
  local text_len = #(self.shadow[row + 1] or "")
  local state = r.h and r.h.state or "none"
  if k == "add" or k == "del" then
    line_bg(buf, row, LINE_HL[k][state])
  elseif k == "edit" then
    line_bg(buf, row, "DifferEditLine")
  end
  draw_syntax(self, buf, row, r, text_len)
  if r.h and not self.dirty[r.f] then
    local words = words_for(r.h, r.f)
    local ranges
    if k == "del" then
      ranges = words.a[r.o - r.h.as + 1]
    elseif k == "add" then
      ranges = words.b[r.w - r.h.bs + 1]
    end
    if ranges then
      local hl = k == "del" and "DifferDelWord" or "DifferAddWord"
      for _, range in ipairs(ranges) do
        if range[1] < text_len then
          mark(buf, row, range[1], { end_col = math.min(range[2], text_len), hl_group = hl, priority = 130 })
        end
      end
    end
  end
end

api.nvim_set_decoration_provider(NS, {
  on_win = function(_, _, buf)
    return by_buf[buf] ~= nil
  end,
  on_line = function(_, _, buf, row)
    local self = by_buf[buf]
    local r = self and self.rows[row + 1]
    if r then
      local ok, err = pcall(draw_row, self, buf, row, r)
      if not ok and not self.draw_error then
        self.draw_error = true
        vim.schedule(function()
          ops.notify("Draw error: " .. tostring(err), vim.log.levels.ERROR)
        end)
      end
    end
  end,
})

--- 'statuscolumn': bar showing stage state, then the file's line number.
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local self = by_buf[api.nvim_win_get_buf(win)]
  local width = self and self.num_width or 3
  local blank = string.rep(" ", width + 2)
  local r = self and self.rows[vim.v.lnum]
  if not r or vim.v.virtnum < 0 then
    return blank
  end
  local k = r.k
  if not (k == "ctx" or k == "add" or k == "del" or k == "edit") then
    return blank
  end
  local icons = config.options.icons
  local bar = " "
  if k == "edit" then
    bar = "%#DifferBarEdit#" .. icons.bar_edit .. "%*"
  elseif r.h and self.kind == "worktree" then
    local state = r.h.state
    if state == "full" then
      bar = "%#DifferBarStaged#" .. icons.bar_staged .. "%*"
    elseif state == "partial" then
      bar = "%#DifferBarPartial#" .. icons.bar_partial .. "%*"
    else
      bar = "%#DifferBarUnstaged#" .. icons.bar .. "%*"
    end
  elseif r.h then
    bar = (k == "del" and "%#DifferDelText#" or "%#DifferAddText#") .. icons.bar .. "%*"
  end
  local number = ""
  if vim.v.virtnum == 0 and r.n then
    number = tostring(r.n)
  end
  local hl = "DifferLnum"
  if vim.v.relnum == 0 and vim.v.virtnum == 0 then
    hl = "DifferLnumCursor"
  elseif k == "add" then
    hl = "DifferLnumAdd"
  end
  return bar .. "%#" .. hl .. "#" .. string.rep(" ", width - #number) .. number .. " %*"
end

--- 'foldtext' for a collapsed file: its header, with stats on the right.
function M.foldtext()
  local buf = api.nvim_get_current_buf()
  local self = by_buf[buf]
  local r = self and self.rows[vim.v.foldstart]
  if not r or r.k ~= "header" then
    return vim.fn.getline(vim.v.foldstart)
  end
  local file = r.f
  local icons = config.options.icons
  local line = self.shadow[vim.v.foldstart] or ""
  local name = line:sub(r.name_s + 1, r.name_e)
  local dir = line:sub(r.name_e + 1)
  local check = line:sub(r.chev_e + 1, r.check_e)
  local stats = ("+%d −%d "):format(file.adds or 0, file.dels or 0)
  local left = "  " .. icons.collapsed .. check
  local used = vim.fn.strdisplaywidth(left .. name .. dir .. stats)
  local total = api.nvim_win_get_width(0) - (vim.fn.getwininfo(api.nvim_get_current_win())[1].textoff or 0)
  return {
    { left, "DifferHeaderDim" },
    { name, "DifferHeaderName" },
    { dir, "DifferHeaderDir" },
    { string.rep(" ", math.max(total - used, 1)), "DifferHeader" },
    { ("+%d"):format(file.adds or 0), "DifferAddText" },
    { (" −%d "):format(file.dels or 0), "DifferDelText" },
  }
end

function M.for_buf(buf)
  return by_buf[buf]
end

return M
