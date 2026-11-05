-- Headless test suite. Run with:
--   nvim --headless --clean -u NONE -l tests/run.lua
-- Each test drives real git in a throwaway repository.
local PROJECT = vim.fn.getcwd()
vim.opt.runtimepath:prepend(PROJECT)
vim.opt.packpath = {}
vim.cmd.runtime("plugin/differ.lua")

local git = require("differ.git")
local diff = require("differ.diff")
local graph = require("differ.graph")
local ops = require("differ.ops")
local config = require("differ.config")
config.setup({ confirm_restore = false, poll_ms = 0 })

local passed, failed = 0, {}
local function eq(got, want, label)
  if not vim.deep_equal(got, want) then
    error(("%s\n  want: %s\n  got:  %s"):format(label or "values differ", vim.inspect(want), vim.inspect(got)), 2)
  end
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failed[#failed + 1] = name .. "\n" .. err
  end
end

local function wait(cond, label)
  if not vim.wait(4000, cond, 10) then
    error("timed out waiting for " .. (label or "condition"), 2)
  end
end

local counter = 0
local function repo()
  counter = counter + 1
  local dir = vim.fn.tempname() .. "-differ-" .. counter
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  local function g(...)
    local ok, out, err = git.sync(dir, { ... })
    if not ok then
      error("git " .. table.concat({ ... }, " ") .. ": " .. err)
    end
    return out
  end
  g("init", "-q", "-b", "main")
  g("config", "user.email", "t@example.com")
  g("config", "user.name", "Tester")
  g("config", "commit.gpgsign", "false")
  local function write(path, text)
    local full = dir .. "/" .. path
    vim.fn.mkdir(vim.fs.dirname(full), "p")
    local fd = assert(io.open(full, "wb"))
    fd:write(text)
    fd:close()
  end
  local function read(path)
    return git.read_work(dir, path)
  end
  return dir, g, write, read
end

local function lines(n, prefix)
  local t = {}
  for i = 1, n do
    t[i] = (prefix or "line") .. i
  end
  return table.concat(t, "\n") .. "\n"
end

-- diff.lua -----------------------------------------------------------------

test("hunks normalise insertions and deletions", function()
  eq(diff.hunks("a\nb\n", "a\nX\nb\n"), { { as = 2, ac = 0, bs = 2, bc = 1 } })
  eq(diff.hunks("a\nb\n", "a\n"), { { as = 2, ac = 1, bs = 2, bc = 0 } })
end)

test("missing final newline is a change and round-trips", function()
  local h = diff.hunks("a", "a\n")
  eq(#h, 1)
  local all = diff.apply(diff.split("a"), diff.split("a\n"), h, function() return true end)
  eq(all, "a\n")
end)

test("stage then unstage one of two hunks is exact", function()
  local head = lines(20)
  local work = head:gsub("line3\n", "THREE\n"):gsub("line17\n", "SEVENTEEN\n")
  local hunks = diff.hunks(head, work)
  eq(#hunks, 2)
  local index = diff.stage(head, head, work, hunks[1])
  eq(index, (head:gsub("line3\n", "THREE\n")))
  eq(diff.stage_state(hunks[1], diff.hunks(head, index), diff.hunks(index, work)), "full")
  eq(diff.stage_state(hunks[2], diff.hunks(head, index), diff.hunks(index, work)), "none")
  eq(diff.unstage(head, index, work, hunks[1]), head)
end)

test("staging selected lines takes only those lines", function()
  local head = "a\nb\nc\n"
  local work = "a\nB1\nB2\nc\n"
  local h = diff.hunks(head, work)[1]
  local index = diff.stage(head, head, work, h, { a = {}, b = { [2] = true } })
  eq(index, "a\nb\nB1\nc\n")
  index = diff.stage(head, head, work, h, { a = { [2] = true }, b = { [2] = true } })
  eq(index, "a\nB1\nc\n")
end)

test("unstaging selected lines reverts only those lines", function()
  local head = "a\nb\nc\n"
  local work = "a\nB1\nB2\nc\n"
  local h = diff.hunks(head, work)[1]
  eq(diff.unstage(head, work, work, h, { a = {}, b = { [3] = true } }), "a\nB1\nc\n")
end)

test("restore puts one hunk back", function()
  local head = lines(20)
  local work = head:gsub("line3\n", "THREE\n"):gsub("line17\n", "SEVENTEEN\n")
  local hunks = diff.hunks(head, work)
  eq(diff.restore(head, work, hunks[2]), (head:gsub("line3\n", "THREE\n")))
end)

test("restore selected lines", function()
  local head = "a\nb\nc\n"
  local work = "a\nB1\nB2\nc\n"
  local h = diff.hunks(head, work)[1]
  eq(diff.restore(head, work, h, { a = {}, b = { [3] = true } }), "a\nB1\nc\n")
end)

test("word diff finds changed words, skips rewrites", function()
  local a, b = diff.word_diff({ "against three runtimes" }, { "against four runtimes" })
  eq(a[1], { { 8, 13 } })
  eq(b[1], { { 8, 12 } })
  a, b = diff.word_diff({ "completely different" }, { "nothing alike here!" })
  eq(next(a), nil)
  eq(next(b), nil)
end)

test("excerpts merge nearby hunks and clamp", function()
  local x = diff.excerpts({ { bs = 2, bc = 1 }, { bs = 6, bc = 1 }, { bs = 50, bc = 0 } }, 50, 3)
  eq(x, { { s = 1, e = 9 }, { s = 47, e = 50 } })
end)

-- graph.lua ----------------------------------------------------------------

local function row_text(cells)
  local t = {}
  for _, c in ipairs(cells) do
    t[#t + 1] = c[1]
  end
  return table.concat(t)
end

test("graph: linear history stays in one lane", function()
  local g = graph.new()
  eq(row_text(g:add("c", { "b" }).cells), "●")
  eq(row_text(g:add("b", { "a" }).cells), "●")
  eq(row_text(g:add("a", {}).cells), "●")
  eq(#g.lanes, 0)
end)

test("graph: merge opens a lane and branch closes into first parent", function()
  local g = graph.new()
  --   m  (merge of p1, p2)
  --   p2 (branch, parent base)
  --   p1 (parent base)
  --   base
  local r = g:add("m", { "p1", "p2" })
  eq(row_text(r.cells), "⊙─╮")
  eq(row_text(r.cont), "│ │")
  r = g:add("p2", { "base" })
  eq(row_text(r.cells), "│ ●")
  r = g:add("p1", { "base" })
  eq(row_text(r.cells), "● │")
  r = g:add("base", {})
  eq(row_text(r.cells), "●─╯")
  eq(#g.lanes, 0)
end)

test("graph: a through lane crosses a connector", function()
  local g = graph.new()
  g:add("x", { "x1" })           -- lane 1
  g:add("y", { "y1" })           -- lane 2
  local r = g:add("x1", { "p", "q" })
  eq(row_text(r.cells), "⊙─┼─╮")
end)

test("graph: two tips on one parent converge", function()
  local g = graph.new()
  g:add("t1", { "p" })
  g:add("t2", { "p" })
  local r = g:add("p", {})
  eq(row_text(r.cells), "●─╯")
end)

-- git.lua ------------------------------------------------------------------

test("status parses modified, staged, renamed, untracked and odd names", function()
  local dir, g, write = repo()
  write("mod.txt", "a\n")
  write("old.txt", lines(30))
  write("sp ace.txt", "x\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("mod.txt", "b\n")
  write("sp ace.txt", "y\n")
  write("new file.txt", "n\n")
  g("mv", "old.txt", "renamed.txt")
  local status
  git.status(dir, function(s) status = s end)
  wait(function() return status end, "status")
  local by = {}
  for _, f in ipairs(status.files) do by[f.path] = f end
  eq(status.branch, "main")
  eq(by["mod.txt"].y, "M")
  eq(by["mod.txt"].adds, 1)
  eq(by["sp ace.txt"].dels, 1)
  eq(by["new file.txt"].kind, "untracked")
  eq(by["renamed.txt"].old_path, "old.txt")
end)

test("cat_file handles missing objects and binary data", function()
  local dir, g, write = repo()
  write("bin", "a\0b\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  local got
  git.cat_file(dir, { "HEAD:nope", "HEAD:bin", ":bin" }, function(r) got = r end)
  wait(function() return got end, "cat_file")
  eq(got[1], nil)
  eq(got[2], "a\0b\n")
  eq(got[3], "a\0b\n")
end)

test("log returns commits oldest last with refs", function()
  local dir, g, write = repo()
  write("a", "1\n")
  g("add", "-A")
  g("commit", "-qm", "first")
  write("a", "2\n")
  g("commit", "-qam", "second subject")
  g("tag", "v1")
  local commits
  git.log(dir, { count = 10 }, function(c) commits = c end)
  wait(function() return commits end, "log")
  eq(#commits, 2)
  eq(commits[1].subject, "second subject")
  eq(#commits[1].parents, 1)
  eq(#commits[2].parents, 0)
  assert(commits[1].refs:find("v1", 1, true))
end)

-- ops.lua against real git -------------------------------------------------

local function status_of(dir)
  local _, out = git.sync(dir, { "status", "--porcelain" })
  return out
end

test("toggle_hunk stages exactly one hunk in real git", function()
  local dir, g, write = repo()
  write("f.txt", lines(20))
  g("add", "-A")
  g("commit", "-qm", "one")
  local work = lines(20):gsub("line3\n", "THREE\n"):gsub("line17\n", "SEVENTEEN\n")
  write("f.txt", work)
  local file = { path = "f.txt", x = ".", y = "M", mode_index = "100644" }
  local hunks = diff.hunks(lines(20), work)
  ops.toggle_hunk(dir, file, hunks[1])
  local cached = g("diff", "--cached", "--unified=0")
  assert(cached:find("THREE", 1, true), "first hunk staged")
  assert(not cached:find("SEVENTEEN", 1, true), "second hunk not staged")
  ops.toggle_hunk(dir, file, hunks[1])
  eq(g("diff", "--cached"), "")
end)

test("toggle_hunk stages a hunk of an untracked file", function()
  local dir, g, write = repo()
  write("seed", "s\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("new.txt", "hello\n")
  local file = { path = "new.txt", kind = "untracked", x = "?", y = "?" }
  ops.toggle_hunk(dir, file, { as = 1, ac = 0, bs = 1, bc = 1 })
  eq(status_of(dir), "A  new.txt\n")
end)

test("stage keeps the executable bit", function()
  local dir, g, write = repo()
  write("run.sh", lines(5))
  vim.uv.fs_chmod(dir .. "/run.sh", 493)
  g("add", "-A")
  g("commit", "-qm", "one")
  local work = lines(5):gsub("line2\n", "TWO\n")
  write("run.sh", work)
  local file = { path = "run.sh", x = ".", y = "M", mode_index = "100755", mode_work = "100755" }
  ops.toggle_hunk(dir, file, diff.hunks(lines(5), work)[1])
  assert(g("ls-files", "-s", "run.sh"):find("^100755"), "mode preserved")
end)

test("restore_hunk reverts worktree and index for that hunk only", function()
  local dir, g, write, read = repo()
  write("f.txt", lines(20))
  g("add", "-A")
  g("commit", "-qm", "one")
  local work = lines(20):gsub("line3\n", "THREE\n"):gsub("line17\n", "SEVENTEEN\n")
  write("f.txt", work)
  g("add", "-A")
  local file = { path = "f.txt", x = "M", y = ".", mode_index = "100644" }
  ops.restore_hunk(dir, file, diff.hunks(lines(20), work)[1])
  eq(read("f.txt"), (lines(20):gsub("line17\n", "SEVENTEEN\n")))
  local cached = g("diff", "--cached")
  assert(not cached:find("THREE", 1, true) and cached:find("SEVENTEEN", 1, true))
end)

test("discard_files handles tracked, untracked and staged-new files", function()
  local dir, g, write, read = repo()
  write("t.txt", "orig\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("t.txt", "changed\n")
  write("u.txt", "untracked\n")
  write("a.txt", "added\n")
  g("add", "a.txt")
  ops.discard_files(dir, {
    { path = "t.txt", kind = "tracked", x = ".", y = "M" },
    { path = "u.txt", kind = "untracked", x = "?", y = "?" },
    { path = "a.txt", kind = "tracked", x = "A", y = "." },
  })
  eq(read("t.txt"), "orig\n")
  eq(read("u.txt"), nil)
  eq(read("a.txt"), nil)
  eq(status_of(dir), "")
end)

-- The whole UI, headless ---------------------------------------------------

local Stream = require("differ.stream")
local App = require("differ.app")

local function open_repo(dir)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  local app = App.open({ path = dir })
  return app
end

local function settle(app)
  wait(function()
    return not app.refreshing and not app.refresh_again and #app.stream.rows > 0
  end, "refresh")
  vim.wait(30)
end

local function close(app)
  vim.bo[app.stream.buf].modified = false
  app.stream.dirty = {}
  app:close(true)
  vim.cmd("silent! %bwipeout!")
end

local function row_index(stream, pred)
  for i, r in ipairs(stream.rows) do
    if pred(r, stream.shadow[i]) then
      return i
    end
  end
  error("no such row")
end

local function buffer_lines(stream)
  return vim.api.nvim_buf_get_lines(stream.buf, 0, -1, false)
end

test("ui: stream renders headers, deleted and added rows in order", function()
  local dir, g, write = repo()
  write("a.txt", lines(20))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", (lines(20):gsub("line10\n", "line10 changed\n")))
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  eq(#buffer_lines(s), #s.rows, "rows match buffer")
  local kinds = {}
  for _, r in ipairs(s.rows) do kinds[#kinds + 1] = r.k end
  eq(kinds, { "header", "sep", "ctx", "ctx", "ctx", "del", "add", "ctx", "ctx", "ctx", "sep" })
  eq(buffer_lines(s)[6], "line10")
  eq(buffer_lines(s)[7], "line10 changed")
  close(app)
end)

test("ui: editing a line and :w writes it back to the file", function()
  local dir, g, write, read = repo()
  write("a.txt", lines(20))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", (lines(20):gsub("line10\n", "line10 changed\n")))
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  vim.api.nvim_set_current_win(app.main_win)
  local add = row_index(s, function(r) return r.k == "add" end)
  vim.api.nvim_win_set_cursor(app.main_win, { add, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.buf })
  eq(vim.bo[s.buf].modifiable, true, "editable on an added line")
  vim.api.nvim_buf_set_lines(s.buf, add - 1, add, false, { "edited line", "inserted line" })
  vim.wait(200, function() return s:is_dirty() end)
  assert(s:is_dirty(), "file marked dirty")
  vim.cmd("silent write")
  local want = lines(20):gsub("line10\n", "edited line\ninserted line\n")
  eq(read("a.txt"), want)
  eq(s:is_dirty(), false)
  settle(app)
  wait(function() return not app.refreshing end)
  vim.wait(100)
  eq(vim.bo[s.buf].modified, false)
  assert(table.concat(buffer_lines(s), "\n"):find("inserted line", 1, true))
  close(app)
end)

test("ui: deleting every row of an excerpt removes those lines", function()
  local dir, g, write, read = repo()
  write("a.txt", lines(5))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", lines(5) .. "added\n")
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  vim.api.nvim_set_current_win(app.main_win)
  local first = row_index(s, function(r) return r.k == "ctx" end)
  local last = first
  while s.rows[last + 1] and (s.rows[last + 1].k == "ctx" or s.rows[last + 1].k == "add") do
    last = last + 1
  end
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, first - 1, last, false, {})
  vim.wait(200, function() return s:is_dirty() end)
  vim.cmd("silent write")
  eq(read("a.txt"), "line1\nline2\n")
  close(app)
end)

test("ui: edits spanning protected rows are rolled back", function()
  local dir, g, write = repo()
  write("a.txt", lines(20))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", (lines(20):gsub("line10\n", "line10 changed\n")))
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  vim.api.nvim_set_current_win(app.main_win)
  local before = buffer_lines(s)
  vim.bo[s.buf].modifiable = true
  -- `dG` from the header's next row: takes out deleted lines too.
  vim.api.nvim_buf_set_lines(s.buf, 2, -1, false, {})
  wait(function() return #buffer_lines(s) == #before end, "rollback")
  eq(buffer_lines(s), before)
  eq(#s.rows, #before)
  eq(s:is_dirty(), false)
  close(app)
end)

test("ui: the cursor on a deleted row makes the buffer read-only", function()
  local dir, g, write = repo()
  write("a.txt", lines(20))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", (lines(20):gsub("line10\n", "line10 changed\n")))
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  vim.api.nvim_set_current_win(app.main_win)
  local del = row_index(s, function(r) return r.k == "del" end)
  vim.api.nvim_win_set_cursor(app.main_win, { del, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.buf })
  eq(vim.bo[s.buf].modifiable, false)
  close(app)
end)

test("ui: undo after an edit keeps rows in step, and render clears undo", function()
  local dir, g, write = repo()
  write("a.txt", lines(20))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", (lines(20):gsub("line10\n", "line10 changed\n")))
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  vim.api.nvim_set_current_win(app.main_win)
  local add = row_index(s, function(r) return r.k == "add" end)
  vim.api.nvim_win_set_cursor(app.main_win, { add, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.buf })
  local before = buffer_lines(s)
  vim.cmd("normal! Ax")
  vim.wait(300, function() return s:is_dirty() end)
  assert(s:is_dirty())
  vim.cmd("undo")
  eq(buffer_lines(s), before)
  vim.wait(400, function() return not s:is_dirty() end)
  eq(s:is_dirty(), false, "undoing back to the original clears dirty")
  eq(vim.bo[s.buf].modified, false)
  -- Nothing left to undo past the render.
  vim.cmd("silent! undo")
  eq(buffer_lines(s), before, "render is not undoable")
  close(app)
end)

test("ui: stage key stages the hunk under the cursor", function()
  local dir, g, write = repo()
  write("a.txt", lines(40))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", (lines(40):gsub("line3\n", "THREE\n"):gsub("line30\n", "THIRTY\n")))
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  vim.api.nvim_set_current_win(app.main_win)
  local add = row_index(s, function(_, t) return t == "THIRTY" end)
  vim.api.nvim_win_set_cursor(app.main_win, { add, 0 })
  s:stage()
  settle(app)
  wait(function() return g("diff", "--cached"):find("THIRTY", 1, true) end, "staged")
  assert(not g("diff", "--cached"):find("THREE", 1, true))
  wait(function()
    local i = row_index(s, function(_, t) return t == "THIRTY" end)
    return s.rows[i].h.state == "full"
  end, "row shows staged")
  close(app)
end)

test("ui: a refresh with no changes keeps rows tied to the file list", function()
  local dir, g, write = repo()
  write("a.txt", lines(20))
  write("b.txt", lines(20))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", (lines(20):gsub("line10\n", "A\n")))
  write("b.txt", (lines(20):gsub("line10\n", "B\n")))
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  local before = s.by_path["b.txt"]
  local fired = false
  app:refresh()
  wait(function() return not app.refreshing end)
  vim.wait(50)
  eq(s.by_path["b.txt"], before, "same object")
  fired = s:file_range(s.by_path["b.txt"]) ~= nil
  assert(fired, "file_range finds the file after a refresh")
  s:jump_to("b.txt")
  local cursor = vim.api.nvim_win_get_cursor(app.main_win)
  eq(s.rows[cursor[1] ].f.path, "b.txt")
  close(app)
end)

test("ui: a refresh during edits leaves them alone, and :w catches up", function()
  local dir, g, write, read = repo()
  write("a.txt", lines(20))
  write("b.txt", lines(20))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", (lines(20):gsub("line10\n", "A\n")))
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  vim.api.nvim_set_current_win(app.main_win)
  local i = row_index(s, function(_, t) return t == "A" end)
  vim.api.nvim_win_set_cursor(app.main_win, { i, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.buf })
  vim.api.nvim_buf_set_lines(s.buf, i - 1, i, false, { "EDITED" })
  vim.wait(200, function() return s:is_dirty() end)
  -- Something else changes another file meanwhile.
  write("b.txt", (lines(20):gsub("line2\n", "B\n")))
  app:refresh()
  wait(function() return not app.refreshing end)
  vim.wait(50)
  assert(table.concat(buffer_lines(s), "\n"):find("EDITED", 1, true), "edit still there")
  vim.cmd("silent write")
  eq(read("a.txt"), (lines(20):gsub("line10\n", "EDITED\n")))
  wait(function() return not app.refreshing and s.by_path["b.txt"] ~= nil end, "catch up")
  wait(function() return table.concat(buffer_lines(s), "\n"):find("b.txt", 1, true) end, "other file appears")
  close(app)
end)

test("ops: find_buffer is exact, not a pattern", function()
  local dir, _, write = repo()
  write("foo.txt", "x\n")
  write("foo.txt.bak", "y\n")
  vim.cmd("edit " .. dir .. "/foo.txt.bak")
  eq(ops.find_buffer(dir, "foo.txt"), nil)
  eq(ops.find_buffer(dir, "foo.txt.bak"), vim.api.nvim_get_current_buf())
  vim.cmd("silent! %bwipeout!")
end)

test("ui: visual selection stages only those lines", function()
  local dir, g, write = repo()
  write("a.txt", "a\nb\nc\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", "a\nX1\nX2\nc\n")
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  vim.api.nvim_set_current_win(app.main_win)
  local x2 = row_index(s, function(_, t) return t == "X2" end)
  vim.api.nvim_win_set_cursor(app.main_win, { x2, 0 })
  s:stage(x2)
  wait(function() return g("show", ":a.txt") == "a\nb\nX2\nc\n" end, "line staged")
  close(app)
end)

test("ui: expanding a hidden gap reveals lines", function()
  local dir, g, write = repo()
  write("a.txt", lines(100))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", (lines(100):gsub("line50\n", "FIFTY\n")))
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  vim.api.nvim_set_current_win(app.main_win)
  local before = #s.rows
  vim.api.nvim_win_set_cursor(app.main_win, { 2, 0 })
  eq(s.rows[2].k, "sep")
  s:activate()
  assert(#s.rows > before, "rows added")
  eq(#buffer_lines(s), #s.rows, "rows match buffer")
  assert(table.concat(buffer_lines(s), "\n"):find("line40", 1, true), "reveals nearby lines")
  -- Editing inside the revealed part still lands in the right place.
  local i = row_index(s, function(_, t) return t == "line40" end)
  vim.api.nvim_win_set_cursor(app.main_win, { i, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.buf })
  vim.api.nvim_buf_set_lines(s.buf, i - 1, i, false, { "FORTY" })
  vim.wait(200, function() return s:is_dirty() end)
  vim.cmd("silent write")
  eq(git.read_work(dir, "a.txt"), (lines(100):gsub("line50\n", "FIFTY\n"):gsub("line40\n", "FORTY\n")))
  close(app)
end)

test("ui: large repos load only up to the budget, then on demand", function()
  local dir, g, write = repo()
  write("seed", "s\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  config.options.load_budget = 50
  for i = 1, 30 do
    write(("f%02d.txt"):format(i), lines(10))
  end
  local app = open_repo(dir)
  settle(app)
  local s = app.stream
  local loaded = 0
  for _, f in ipairs(s.files) do
    if f.loaded then loaded = loaded + 1 end
  end
  assert(loaded > 0 and loaded < 30, "partial load, got " .. loaded)
  local last = s.files[#s.files]
  eq(last.loaded, nil)
  local done
  s:load_file(last, function() done = true end)
  wait(function() return done end, "load on demand")
  assert(last.loaded)
  eq(#buffer_lines(s), #s.rows, "rows match buffer")
  config.options.load_budget = config.defaults.load_budget
  close(app)
end)

test("ui: panel lists files with state and toggles stage", function()
  local dir, g, write = repo()
  write("a.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", "2\n")
  write("sub/new.txt", "n\n")
  local app = open_repo(dir)
  settle(app)
  wait(function() return app.panel.status end, "panel status")
  local p = app.panel
  local text = table.concat(vim.api.nvim_buf_get_lines(p.changes_buf, 0, -1, false), "\n")
  assert(text:find("Tracked", 1, true) and text:find("Untracked", 1, true), text)
  assert(text:find("a.txt", 1, true) and text:find("new.txt sub", 1, true), text)
  local file
  for _, item in ipairs(p.items) do
    if item.k == "file" and item.file.path == "a.txt" then file = item.file end
  end
  app:toggle_files({ file })
  wait(function() return g("diff", "--cached"):find("+2", 1, true) end, "staged")
  close(app)
end)

test("ui: history shows the graph; selecting a commit shows its diff read-only", function()
  local dir, g, write = repo()
  write("a.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "base commit")
  g("checkout", "-qb", "side")
  write("b.txt", "side\n")
  g("add", "-A")
  g("commit", "-qm", "side commit")
  g("checkout", "-q", "main")
  write("a.txt", "2\n")
  g("commit", "-qam", "main commit")
  g("merge", "-q", "--no-edit", "side")
  local app = open_repo(dir)
  wait(function() return not app.refreshing end)
  local p = app.panel
  app:switch_tab("history")
  wait(function() return #p.commits == 4 end, "commits")
  local text = table.concat(vim.api.nvim_buf_get_lines(p.history_buf, 0, -1, false), "\n")
  assert(text:find("⊙", 1, true) or text:find("◉", 1, true), text)
  assert(text:find("side commit", 1, true) and text:find("╮", 1, true), text)
  -- Show "main commit".
  local commit
  for _, c in ipairs(p.commits) do
    if c.subject == "main commit" then commit = c end
  end
  app:show_commit(commit)
  wait(function() return app.commit_stream ~= nil end, "commit stream")
  local cs = app.commit_stream
  eq(vim.api.nvim_win_get_buf(app.main_win), cs.buf)
  assert(table.concat(buffer_lines(cs), "\n"):find("main commit", 1, true))
  eq(vim.bo[cs.buf].modifiable, false)
  close(app)
end)

test("ui: split mode diffs against HEAD with the real buffer on the right", function()
  local dir, g, write = repo()
  write("a.lua", "local a = 1\nreturn a\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.lua", "local a = 2\nreturn a\n")
  local app = open_repo(dir)
  settle(app)
  app:toggle_mode()
  wait(function() return app.split:is_open() end, "split open")
  local left = app.split.left_win
  assert(vim.wo[left].diff and vim.wo[app.main_win].diff, "both in diff mode")
  eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(app.main_win)), dir .. "/a.lua")
  eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(left), 0, 1, false)[1], "local a = 1")
  -- Back to unified leaves no diff state behind.
  app:toggle_mode()
  eq(app.split:is_open(), false)
  eq(vim.wo[app.main_win].diff, false)
  eq(vim.api.nvim_win_get_buf(app.main_win), app.stream.buf)
  close(app)
end)

test("ui: commit from the box commits what's staged", function()
  local dir, g, write = repo()
  write("a.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", "2\n")
  g("add", "-A")
  local app = open_repo(dir)
  settle(app)
  wait(function() return app.panel.status end)
  vim.api.nvim_buf_set_lines(app.panel.commit_buf, 0, -1, false, { "my message" })
  app.panel:commit()
  wait(function() return g("log", "-1", "--format=%s") == "my message\n" end, "commit made")
  wait(function() return vim.api.nvim_buf_get_lines(app.panel.commit_buf, 0, 1, false)[1] == "" end, "box cleared")
  close(app)
end)

test("ui: amend rewrites the last commit", function()
  local dir, g, write = repo()
  write("a.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "original")
  write("a.txt", "2\n")
  g("add", "-A")
  local app = open_repo(dir)
  settle(app)
  wait(function() return app.panel.status end)
  app.panel:toggle_amend()
  eq(vim.api.nvim_buf_get_lines(app.panel.commit_buf, 0, 1, false)[1], "original", "prefills message")
  vim.api.nvim_buf_set_lines(app.panel.commit_buf, 0, -1, false, { "reworded" })
  app.panel:commit()
  wait(function() return g("log", "-1", "--format=%s") == "reworded\n" end, "amended")
  eq(vim.trim(g("rev-list", "--count", "HEAD")), "1", "no new commit")
  eq(g("status", "--porcelain"), "")
  close(app)
end)

test("ui: nothing staged and declining the prompt doesn't commit", function()
  local dir, g, write = repo()
  write("a.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", "2\n")
  local app = open_repo(dir)
  settle(app)
  wait(function() return app.panel.status end)
  vim.api.nvim_buf_set_lines(app.panel.commit_buf, 0, -1, false, { "should not exist" })
  local confirm = vim.fn.confirm
  vim.fn.confirm = function() return 2 end
  app.panel:commit()
  vim.fn.confirm = confirm
  vim.wait(100)
  eq(g("log", "-1", "--format=%s"), "one\n")
  close(app)
end)

test("ui: push and pull work against a real remote", function()
  local dir, g, write = repo()
  local bare = vim.fn.tempname() .. "-bare"
  vim.fn.mkdir(bare, "p")
  git.sync(bare, { "init", "-q", "--bare", "-b", "main" })
  write("a.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  g("remote", "add", "origin", bare)
  g("push", "-q", "-u", "origin", "main")
  write("a.txt", "2\n")
  g("commit", "-qam", "two")
  local app = open_repo(dir)
  wait(function() return app.panel.status and app.panel.status.ahead == 1 end, "ahead shown")
  app:remote("Push", { "push" })
  wait(function() return vim.trim(select(2, git.sync(bare, { "rev-list", "--count", "main" }))) == "2" end, "pushed")
  wait(function() return app.panel.status.ahead == 0 end, "ahead cleared")
  -- Move the remote on from a second clone, then pull it.
  local other = vim.fn.tempname() .. "-clone"
  vim.system({ "git", "clone", "-q", bare, other }):wait()
  local fd = assert(io.open(other .. "/a.txt", "wb"))
  fd:write("3\n")
  fd:close()
  git.sync(other, { "-c", "user.name=O", "-c", "user.email=o@e", "commit", "-qam", "three" })
  git.sync(other, { "push", "-q" })
  app:remote("Fetch", { "fetch", "--all", "--prune" })
  wait(function() return app.panel.status.behind == 1 end, "behind shown")
  app:remote("Pull", { "pull", "--ff-only" })
  wait(function() return git.read_work(dir, "a.txt") == "3\n" end, "pulled")
  close(app)
end)

test("ui: file history lists only that file's commits, and they connect", function()
  local dir, g, write = repo()
  write("a.txt", "1\n")
  write("b.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "both")
  write("b.txt", "2\n")
  g("commit", "-qam", "only b")
  write("a.txt", "2\n")
  g("commit", "-qam", "only a")
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  require("differ").history(dir .. "/a.txt")
  local app = App.current
  wait(function() return #app.panel.commits == 2 end, "two commits")
  eq(app.panel.commits[1].subject, "only a")
  eq(app.panel.commits[2].subject, "both")
  eq(app.panel.commits[1].parents[1], app.panel.commits[2].hash, "parents rewritten")
  eq(app.panel.tab, "history")
  eq(#app.panel.graph.lanes, 0, "graph closed cleanly")
  close(app)
end)

test("ui: split mode survives another plugin's failing autocmds", function()
  local dir, g, write = repo()
  write("a.lua", "local a = 1\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.lua", "local a = 2\n")
  local group = vim.api.nvim_create_augroup("differ.test.broken", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "FileType" }, {
    group = group, pattern = { "*.lua", "lua" },
    callback = function() error("broken plugin") end,
  })
  local notify, warned = vim.notify, false
  vim.notify = function(msg) if msg:find("broken plugin", 1, true) then warned = true end end
  local app = open_repo(dir)
  settle(app)
  app:toggle_mode()
  wait(function() return app.split:is_open() and vim.wo[app.main_win].diff end, "split built")
  assert(vim.wo[app.split.left_win].diff, "both sides in diff mode")
  wait(function() return warned end, "error reported")
  vim.notify = notify
  vim.api.nvim_del_augroup_by_id(group)
  close(app)
end)

test("ui: split mode opens each file at its first change", function()
  local dir, g, write = repo()
  write("long.txt", lines(60))
  write("short.txt", "a\nb\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("long.txt", (lines(60):gsub("line50\n", "FIFTY\n")))
  write("short.txt", "a\nB\n")
  local app = open_repo(dir)
  settle(app)
  app:toggle_mode()
  wait(function() return app.split:is_open() end, "split")
  eq(app.split.file.path, "long.txt")
  eq(vim.api.nvim_win_get_cursor(app.main_win)[1], 50, "on the change")
  app:step_file(1)
  eq(app.split.file.path, "short.txt")
  eq(vim.api.nvim_win_get_cursor(app.main_win)[1], 2, "on the change")
  eq(vim.fn.line("w0", app.main_win), 1, "short file fully in view")
  close(app)
end)

test("ui: split mode stages the hunk under the cursor on either side", function()
  local dir, g, write = repo()
  write("a.txt", lines(40))
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", (lines(40):gsub("line3\n", "THREE\n"):gsub("line30\n", "THIRTY\n")))
  local app = open_repo(dir)
  settle(app)
  app:toggle_mode()
  wait(function() return app.split:is_open() end, "split")
  vim.api.nvim_set_current_win(app.main_win)
  vim.api.nvim_win_set_cursor(app.main_win, { 30, 0 })
  app.split:_hunk_op("stage")
  wait(function() return g("diff", "--cached"):find("THIRTY", 1, true) end, "staged from right")
  assert(not g("diff", "--cached"):find("THREE", 1, true))
  vim.api.nvim_set_current_win(app.split.left_win)
  vim.api.nvim_win_set_cursor(app.split.left_win, { 3, 0 })
  app.split:_hunk_op("stage")
  wait(function() return g("diff", "--cached"):find("THREE", 1, true) end, "staged from left")
  close(app)
end)

test("ui: split mode refreshes the old side after a commit, then moves on", function()
  local dir, g, write = repo()
  write("a.txt", "1\n")
  write("b.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", "2\n")
  write("b.txt", "2\n")
  local app = open_repo(dir)
  settle(app)
  app:toggle_mode()
  wait(function() return app.split:is_open() end, "split")
  eq(app.split.file.path, "a.txt")
  g("commit", "-qm", "a only", "a.txt")
  app:refresh()
  wait(function() return app.split.file and app.split.file.path == "b.txt" end, "moved to remaining file")
  close(app)
end)

test("ui: closing while git is running raises no error", function()
  local dir, g, write = repo()
  write("a.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", "2\n")
  g("add", "-A")
  local app = open_repo(dir)
  settle(app)
  wait(function() return app.panel.status end)
  local errors = {}
  local notify = vim.notify
  vim.notify = function(msg, level)
    if level == vim.log.levels.ERROR then errors[#errors + 1] = msg end
  end
  vim.api.nvim_buf_set_lines(app.panel.commit_buf, 0, -1, false, { "racing" })
  app.panel:commit()
  app:refresh()
  app:remote("Fetch", { "fetch", "--all" })
  local commit_done = function() return g("log", "-1", "--format=%s") == "racing\n" end
  close(app)
  wait(commit_done, "commit still lands")
  vim.wait(150)
  vim.notify = notify
  eq(errors, {})
  eq(App.current, nil)
end)

local function history_repo()
  local dir, g, write = repo()
  write("a.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "first")
  write("a.txt", "2\n")
  g("commit", "-qam", "second")
  write("a.txt", "3\n")
  return dir
end

test("ui: toggle_tab switches tab and focuses the sidebar from anywhere", function()
  local app = open_repo(history_repo())
  settle(app)
  local p = app.panel
  vim.api.nvim_set_current_win(app.main_win)
  app:toggle_tab()
  eq(p.tab, "history")
  eq(vim.api.nvim_get_current_win(), app.side_win)
  eq(vim.api.nvim_win_get_buf(app.side_win), p.history_buf)
  wait(function() return #p.commits == 2 end, "commits")
  app:toggle_tab()
  eq(p.tab, "changes")
  eq(vim.api.nvim_get_current_win(), app.side_win)
  assert(app.commit_win and vim.api.nvim_win_is_valid(app.commit_win), "commit box back")
  -- From inside the commit box, which closes as part of the switch.
  vim.api.nvim_set_current_win(app.commit_win)
  app:toggle_tab()
  eq(p.tab, "history")
  eq(vim.api.nvim_get_current_win(), app.side_win)
  close(app)
end)

test("ui: the toggle key is bound in every Differ window", function()
  local app = open_repo(history_repo())
  settle(app)
  local function bound(buf)
    return vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("gh", "n", false, true).buffer == 1
    end)
  end
  assert(bound(app.stream.buf), "stream")
  assert(bound(app.panel.changes_buf), "changes")
  assert(bound(app.panel.history_buf), "history")
  assert(bound(app.panel.commit_buf), "commit box")
  app:toggle_mode()
  wait(function() return app.split:is_open() end, "split")
  assert(bound(vim.api.nvim_win_get_buf(app.main_win)), "split: real file")
  assert(bound(vim.api.nvim_win_get_buf(app.split.left_win)), "split: old side")
  local real = vim.api.nvim_win_get_buf(app.main_win)
  app:toggle_mode()
  assert(not bound(real), "unmapped from your real buffer afterwards")
  close(app)
end)

test("ui: returning to History re-shows the commit, Changes shows the worktree", function()
  local app = open_repo(history_repo())
  settle(app)
  local p = app.panel
  app:switch_tab("history")
  wait(function() return #p.commits == 2 end, "commits")
  p:_show_commit({ commit = p.commits[2] })
  wait(function() return app.commit_stream ~= nil end, "commit shown")
  local rev = p.commits[2].hash
  app:toggle_tab()
  eq(vim.api.nvim_win_get_buf(app.main_win), app.stream.buf, "worktree in main pane")
  app:toggle_tab()
  wait(function()
    return vim.api.nvim_win_get_buf(app.main_win) == app.commit_stream.buf and app.commit_stream.rev == rev
  end, "commit back in main pane")
  close(app)
end)

test("help: opens with no view, lists toggle key, closes", function()
  eq(App.current, nil)
  local before = vim.api.nvim_get_current_win()
  vim.cmd("Differ help")
  local win = vim.api.nvim_get_current_win()
  assert(win ~= before and vim.api.nvim_win_get_config(win).relative ~= "", "float opened")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(text:find("gh", 1, true) and text:find("Changes and History", 1, true), text)
  vim.cmd("normal q")
  eq(vim.api.nvim_get_current_win(), before)
end)

test("help: a key set to false is left out instead of crashing", function()
  local keep = config.options
  config.setup({ keys = { stream = { stage_all = false, unstage_all = false }, common = { toggle_tab = false } } })
  local lines = require("differ.help").lines()
  local text = table.concat(lines, "\n")
  assert(not text:find("switch between Changes and History", 1, true), "disabled key hidden")
  config.options = keep
end)

test("cheatsheet.txt parses and mentions every default key", function()
  local text = table.concat(vim.fn.readfile(PROJECT .. "/cheatsheet.txt"), "\n")
  for line in text:gmatch("[^\n]+") do
    if line:sub(1, 1) ~= "#" then
      assert(line:find(" | ", 1, true), "needs 'description | key': " .. line)
    end
  end
  local cheats = {}
  for key in text:gmatch("|%s*([^\n]+)") do
    for one in key:gmatch("%S+") do
      cheats[one] = true
    end
  end
  for group, map in pairs(config.defaults.keys) do
    for name, lhs in pairs(map) do
      assert(cheats[lhs], ("keys.%s.%s (%s) is missing from cheatsheet.txt"):format(group, name, lhs))
    end
  end
end)

test("ui: global window maps are left alone in Differ's windows", function()
  vim.keymap.set("n", "<C-h>", "<C-w>h")
  local dir, g, write = repo()
  write("a.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  write("a.txt", "2\n")
  local app = open_repo(dir)
  settle(app)
  vim.api.nvim_set_current_win(app.side_win)
  eq(vim.fn.maparg("<C-h>", "n", false, true).buffer, 0, "not overridden in the sidebar")
  vim.api.nvim_set_current_win(app.main_win)
  eq(vim.fn.maparg("<C-h>", "n", false, true).buffer, 0, "not overridden in the stream")
  close(app)
end)

test("ui: an empty repository opens without error", function()
  local dir = repo()
  local app = open_repo(dir)
  settle(app)
  close(app)
end)

test("ui: closing returns to the original tab and cleans up", function()
  local dir, g, write = repo()
  write("a.txt", "1\n")
  g("add", "-A")
  g("commit", "-qm", "one")
  local tabs = #vim.api.nvim_list_tabpages()
  local origin = vim.api.nvim_get_current_tabpage()
  local app = open_repo(dir)
  settle(app)
  eq(#vim.api.nvim_list_tabpages(), tabs + 1)
  local bufs = { app.stream.buf, app.panel.changes_buf }
  app:close()
  eq(#vim.api.nvim_list_tabpages(), tabs)
  eq(vim.api.nvim_get_current_tabpage(), origin)
  eq(App.current, nil)
  for _, b in ipairs(bufs) do
    eq(vim.api.nvim_buf_is_valid(b), false)
  end
  eq(Stream.for_buf(bufs[1]), nil)
end)

print(("%d passed, %d failed"):format(passed, #failed))
for _, f in ipairs(failed) do
  print("\nFAIL: " .. f)
end
vim.cmd(#failed == 0 and "qa!" or "cq!")
