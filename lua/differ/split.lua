-- Side-by-side view for one file, using nvim's native diff mode. On the worktree
-- the right pane is your real file buffer, so LSP, formatting, completion and
-- `:w` all behave as usual.
local M = {}

local api = vim.api
local diff = require("differ.diff")
local config = require("differ.config")
local ops = require("differ.ops")

local Split = {}
Split.__index = Split

function M.new(app)
  return setmetatable({ app = app, mapped = {} }, Split)
end

function Split:is_open()
  return self.file ~= nil
end

--- Run something that fires other plugins' autocmds (filetype, BufRead). An
--- error in their handler (say, an LSP config whose tool isn't installed) is
--- reported, but mustn't leave the split half built.
local function guarded(what, fn)
  local ok, err = pcall(fn)
  if not ok then
    vim.schedule(function()
      -- First line only: the full traceback belongs to that plugin, not to us.
      local first = tostring(err):match("[^\n]*"):gsub("^.-: ", "", 1)
      ops.notify(("Another plugin failed while %s (Differ carried on):\n%s"):format(what, first), vim.log.levels.WARN)
    end)
  end
end

local function scratch_buf(name, lines, path)
  local buf = api.nvim_create_buf(false, true)
  pcall(api.nvim_buf_set_name, buf, name)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
  bo.bufhidden = "wipe"
  bo.swapfile = false
  bo.buflisted = false
  bo.modifiable = false
  local ok, ft = pcall(vim.filetype.match, { filename = path, buf = buf })
  if ok and ft then
    guarded("setting the filetype", function()
      bo.filetype = ft
    end)
  end
  return buf
end

local function stripped(raw)
  return vim.tbl_map(diff.strip, raw)
end

local LEFT_HL = table.concat({
  "DiffAdd:DifferDelLine", "DiffChange:DifferDelLine", "DiffText:DifferDelWord",
  "DiffTextAdd:DifferDelWord", "DiffDelete:DifferFiller",
}, ",")
local RIGHT_HL = table.concat({
  "DiffAdd:DifferAddLine", "DiffChange:DifferAddLine", "DiffText:DifferAddWord",
  "DiffTextAdd:DifferAddWord", "DiffDelete:DifferFiller",
}, ",")

local function setup_window(win, highlight)
  local wo = vim.wo[win]
  wo.number = true
  wo.relativenumber = false
  wo.statuscolumn = ""
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.spell = false
  wo.wrap = false
  wo.cursorline = true
  wo.fillchars = "diff:╱,eob: ,fold: "
  wo.foldtext = ""
  wo.winhighlight = highlight
end

function Split:_unmap()
  for buf, keys in pairs(self.mapped) do
    if api.nvim_buf_is_valid(buf) then
      for _, item in ipairs(keys) do
        pcall(vim.keymap.del, item[1], item[2], { buffer = buf })
      end
    end
  end
  self.mapped = {}
end

function Split:_map(buf)
  local app = self.app
  local list = {}
  self.mapped[buf] = list
  local function m(mode, lhs, fn, desc)
    if lhs then
      vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Differ: " .. desc })
      list[#list + 1] = { mode, lhs }
    end
  end
  local stream_keys = config.options.keys.stream
  local common = config.options.keys.common
  m("n", common.close, function() app:close() end, "close")
  m("n", common.toggle_mode, function() app:toggle_mode() end, "unified view")
  m("n", common.toggle_tab, function() app:toggle_tab() end, "switch Changes / History")
  m("n", common.help, function() app:help() end, "help")
  m("n", common.refresh, function() app:refresh() end, "refresh")
  m("n", common.commit, function() app:focus_commit() end, "write commit message")
  m("n", stream_keys.next_file, function() app:step_file(1) end, "next file")
  m("n", stream_keys.prev_file, function() app:step_file(-1) end, "previous file")
  m("n", stream_keys.next_file_alt, function() app:step_file(1) end, "next file")
  m("n", stream_keys.prev_file_alt, function() app:step_file(-1) end, "previous file")
  if self.stream.kind == "worktree" then
    m("n", stream_keys.stage, function() self:_hunk_op("stage") end, "stage or unstage hunk")
    m("n", stream_keys.restore, function() self:_hunk_op("restore") end, "restore hunk to HEAD")
  end
end

--- Stage or restore the hunk under the cursor, on either pane.
function Split:_hunk_op(op)
  local win = api.nvim_get_current_win()
  local line = api.nvim_win_get_cursor(win)[1]
  local on_left = win == self.left_win
  local file = self.file
  local root = self.app.root
  if not ops.buffer_guard(root, file.path) then
    return
  end
  local snap = ops.snapshot(root, file)
  local hunks = diff.hunks(snap.head, snap.work)
  local hit
  for _, h in ipairs(hunks) do
    local s, c = h.bs, h.bc
    if on_left then
      s, c = h.as, h.ac
    end
    if diff.overlaps(line, 1, s, c) or (c == 0 and line == s - 1) then
      hit = h
      break
    end
  end
  if not hit then
    return ops.notify("No change on this line", vim.log.levels.WARN)
  end
  local changed
  if op == "stage" then
    changed = ops.toggle_hunk(root, file, hit)
  else
    changed = ops.restore_hunk(root, file, hit)
  end
  if changed then
    self.app:refresh()
  end
end

--- Show `file` of `stream` side by side.
function Split:show(stream, file)
  if not file.loaded then
    file.want = true
    stream:load({ file }, function()
      self:show(stream, file)
    end)
    return
  end
  if file.binary_body then
    ops.notify(file.path .. " is binary; nothing to compare", vim.log.levels.WARN)
    return
  end
  self.stream, self.file = stream, file
  local app = self.app
  local main = app.main_win
  self:_unmap()

  local label = stream.kind == "worktree" and "HEAD" or stream.base:sub(1, 8)
  local old_name = ("differ://%s/%s"):format(label, file.old_path or file.path)
  local left = scratch_buf(old_name, stripped(file.H), file.old_path or file.path)
  self.shown_head = file.head

  local right
  local real = stream.kind == "worktree" and vim.uv.fs_stat(app.root .. "/" .. file.path)
  if real then
    right = vim.fn.bufadd(app.root .. "/" .. file.path)
    vim.bo[right].buflisted = true
    guarded("loading " .. file.path, function()
      vim.fn.bufload(right)
    end)
  else
    right = scratch_buf(("differ://%s/%s"):format(stream.rev or "worktree", file.path), stripped(file.W), file.path)
  end

  -- Turn diff off before swapping buffers so stale state can't bleed across.
  if self.left_win and api.nvim_win_is_valid(self.left_win) then
    api.nvim_win_call(self.left_win, function()
      vim.cmd("silent! diffoff")
    end)
    api.nvim_win_set_buf(self.left_win, left)
  else
    self.left_win = api.nvim_open_win(left, false, { split = "left", win = main })
  end
  api.nvim_win_call(main, function()
    vim.cmd("silent! diffoff")
  end)
  api.nvim_win_set_buf(main, right)

  setup_window(self.left_win, LEFT_HL)
  setup_window(main, RIGHT_HL)
  for _, win in ipairs({ self.left_win, main }) do
    api.nvim_win_call(win, function()
      vim.cmd("silent! diffthis")
      vim.wo[win].foldenable = true
    end)
  end
  -- Start at the first change. Without this the previous file's cursor line
  -- carries over through scrollbind, and a short file can scroll out of view.
  for _, win in ipairs({ self.left_win, main }) do
    api.nvim_win_set_cursor(win, { 1, 0 })
  end
  api.nvim_win_call(main, function()
    if vim.fn.diff_hlID(1, 1) == 0 then
      pcall(vim.cmd, "silent! normal! ]c")
    end
    vim.cmd("silent! syncbind")
  end)
  self:_map(left)
  self:_map(right)
  self:_winbars()
  app:on_stream_file(stream, file.path)

  -- Equal panes, with the sidebar keeping its width.
  local width = api.nvim_win_get_width(self.left_win) + api.nvim_win_get_width(main)
  api.nvim_win_set_width(self.left_win, math.floor(width / 2))
end

function Split:_winbars()
  local file = self.file
  local stream = self.stream
  local path = file.path:gsub("%%", "%%%%")
  local old = (file.old_path or file.path):gsub("%%", "%%%%")
  local base = stream.kind == "worktree" and "HEAD" or stream.base:sub(1, 8)
  local head_label = stream.kind == "worktree" and "Working tree" or (stream.rev or ""):sub(1, 8)
  vim.wo[self.left_win].winbar = ("%%#DifferBarDim# %s %%#DifferBarTitle#%s %%#DifferBar#"):format(base, old)
  local function btn(fn, text, hl)
    return ("%%#%s#%%@v:lua.DifferClick.%s@ %s %%X%%#DifferBar# "):format(hl, fn, text)
  end
  vim.wo[self.app.main_win].winbar = ("%%#DifferBarDim# %s %%#DifferBarFile#%s %%#DifferBarAdd#+%d %%#DifferBarDel#−%d %%#DifferBar#%%="):format(
    head_label, path, file.adds or 0, file.dels or 0
  ) .. btn("toggle_mode", "Unified", "DifferBarBtn")
end

--- Keep the view current after a refresh: HEAD may have moved (say, a commit).
function Split:sync()
  if not self:is_open() or self.stream.kind ~= "worktree" then
    return
  end
  local fresh = self.stream.by_path[self.file.path]
  if not fresh then
    -- The file no longer has changes; fall back to the next one or to unified.
    local nxt = self.stream.files[1]
    if nxt then
      self:show(self.stream, nxt)
    else
      self.app:toggle_mode()
    end
    return
  end
  self.file = fresh
  if fresh.loaded and fresh.head ~= self.shown_head then
    self:show(self.stream, fresh)
  else
    pcall(self._winbars, self)
  end
end

function Split:close()
  self:_unmap()
  local main = self.app.main_win
  if main and api.nvim_win_is_valid(main) then
    api.nvim_win_call(main, function()
      vim.cmd("silent! diffoff")
    end)
  end
  if self.left_win and api.nvim_win_is_valid(self.left_win) then
    pcall(api.nvim_win_close, self.left_win, true)
  end
  self.left_win, self.file, self.stream, self.shown_head = nil, nil, nil, nil
end

return M
