-- Everything that changes the repository: staging, unstaging, restoring,
-- committing, syncing. Hunk operations re-read HEAD, the index and the worktree
-- first, so they act on what's on disk now and not on a possibly stale render.
local M = {}

local git = require("differ.git")
local diff = require("differ.diff")
local config = require("differ.config")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Differ" })
end
M.notify = notify

local function head_path(file)
  return file.old_path or file.path
end

--- Fresh HEAD, index and worktree text for a file. head/index are "" if absent.
function M.snapshot(root, file)
  local objs = git.cat_file_sync(root, { "HEAD:" .. head_path(file), ":" .. file.path })
  return {
    head = objs[1] or "",
    has_head = objs[1] ~= nil,
    index = objs[2] or "",
    has_index = objs[2] ~= nil,
    work = git.read_work(root, file.path) or "",
  }
end

--- Find the fresh hunk matching a hunk from an earlier render.
function M.find_hunk(hunks, h)
  for _, o in ipairs(hunks) do
    if diff.overlaps(o.bs, o.bc, h.bs, h.bc) or diff.overlaps(o.as, o.ac, h.as, h.ac) then
      return o
    end
  end
end

local function write_index(root, file, text)
  local ok, oid, err = git.sync(root, { "hash-object", "-w", "--stdin" }, { stdin = text })
  if not ok then
    return false, err
  end
  local mode = file.mode_index
  if not mode or mode == "000000" then
    mode = (file.mode_work and file.mode_work ~= "000000") and file.mode_work or "100644"
  end
  local entry = ("%s,%s,%s"):format(mode, vim.trim(oid), file.path)
  local ok2, _, err2 = git.sync(root, { "update-index", "--add", "--cacheinfo", entry })
  return ok2, err2
end

local function reset_path(root, path)
  return git.sync(root, { "reset", "-q", "--", path })
end

--- Toggle a hunk (or selected lines of it): staged → unstaged, otherwise staged.
--- Returns true if the repository changed.
function M.toggle_hunk(root, file, h, lines)
  local snap = M.snapshot(root, file)
  local fresh = M.find_hunk(diff.hunks(snap.head, snap.work), h)
  if not fresh then
    notify("That hunk no longer exists; refreshing", vim.log.levels.WARN)
    return true
  end
  local state = diff.stage_state(fresh, diff.hunks(snap.head, snap.index), diff.hunks(snap.index, snap.work))
  local ok, err
  if state == "full" then
    local text = diff.unstage(snap.head, snap.index, snap.work, fresh, lines)
    if text == snap.head then
      ok, _, err = reset_path(root, file.path)
    else
      ok, err = write_index(root, file, text)
    end
  else
    ok, err = write_index(root, file, diff.stage(snap.head, snap.index, snap.work, fresh, lines))
  end
  if not ok then
    notify("Could not update the index: " .. tostring(err), vim.log.levels.ERROR)
  end
  return true
end

--- The loaded buffer for a repository file, if there is one.
--- (bufnr() takes a pattern, so it could match some other file.)
function M.find_buffer(root, path)
  local full = root .. "/" .. path
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == full then
      return buf
    end
  end
end

local function buffer_guard(root, path)
  local buf = M.find_buffer(root, path)
  if buf and vim.bo[buf].modified then
    notify(path .. " has unsaved changes in a buffer; save it first", vim.log.levels.WARN)
    return false
  end
  return true
end
M.buffer_guard = buffer_guard

local function reload_buffer(root, path)
  local buf = M.find_buffer(root, path)
  if buf then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! edit!")
    end)
  end
end

--- Write worktree text, recreating the file and its exec bit if needed.
function M.write_work(root, file, text)
  local full = root .. "/" .. file.path
  vim.fn.mkdir(vim.fs.dirname(full), "p")
  local fd, err = io.open(full, "wb")
  if not fd then
    return false, err
  end
  fd:write(text)
  fd:close()
  if file.mode_work == "100755" or (file.mode_index == "100755") then
    vim.uv.fs_chmod(full, 493)
  end
  return true
end

--- Put a hunk (or selected lines) back to HEAD in both worktree and index.
function M.restore_hunk(root, file, h, lines)
  if not buffer_guard(root, file.path) then
    return false
  end
  if config.options.confirm_restore then
    local what = lines and "the selected lines" or "this hunk"
    if vim.fn.confirm(("Restore %s of %s to HEAD? This can't be undone."):format(what, file.path), "&Restore\n&Cancel", 2) ~= 1 then
      return false
    end
  end
  local snap = M.snapshot(root, file)
  local fresh = M.find_hunk(diff.hunks(snap.head, snap.work), h)
  if not fresh then
    return true
  end
  local work_text = diff.restore(snap.head, snap.work, fresh, lines)
  local index_hunks = diff.hunks(snap.head, snap.index)
  if M.find_hunk(index_hunks, fresh) then
    local index_text = diff.unstage(snap.head, snap.index, snap.work, fresh, lines)
    if index_text == snap.head then
      reset_path(root, file.path)
    else
      write_index(root, file, index_text)
    end
  end
  if not snap.has_head and work_text == "" then
    -- Restoring every line of a new file means the file shouldn't exist.
    git.sync(root, { "rm", "-f", "-q", "--cached", "--ignore-unmatch", "--", file.path })
    vim.uv.fs_unlink(root .. "/" .. file.path)
  else
    local ok, err = M.write_work(root, file, work_text)
    if not ok then
      notify("Could not write " .. file.path .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  reload_buffer(root, file.path)
  return true
end

local function pathspec(files)
  local parts = {}
  for _, f in ipairs(files) do
    parts[#parts + 1] = f.path
    if f.old_path then
      parts[#parts + 1] = f.old_path
    end
  end
  return table.concat(parts, "\0") .. "\0"
end

function M.stage_files(root, files)
  if #files == 0 then
    return
  end
  local ok, _, err = git.sync(root, { "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul" }, { stdin = pathspec(files) })
  if not ok then
    notify("git add failed: " .. err, vim.log.levels.ERROR)
  end
end

function M.unstage_files(root, files)
  if #files == 0 then
    return
  end
  local ok, _, err = git.sync(root, { "reset", "-q", "--pathspec-from-file=-", "--pathspec-file-nul" }, { stdin = pathspec(files) })
  if not ok then
    notify("git reset failed: " .. err, vim.log.levels.ERROR)
  end
end

--- Discard all changes to files, after asking. Returns true if anything changed.
function M.discard_files(root, files)
  if #files == 0 then
    return false
  end
  for _, f in ipairs(files) do
    if not buffer_guard(root, f.path) then
      return false
    end
  end
  if config.options.confirm_restore then
    local untracked = 0
    for _, f in ipairs(files) do
      if f.kind == "untracked" or (f.x == "A") then
        untracked = untracked + 1
      end
    end
    local msg = #files == 1 and ("Discard all changes to %s?"):format(files[1].path)
      or ("Discard all changes to %d files?"):format(#files)
    if untracked > 0 then
      msg = msg .. ("\n%d new file%s will be deleted."):format(untracked, untracked == 1 and "" or "s")
    end
    if vim.fn.confirm(msg .. " This can't be undone.", "&Discard\n&Cancel", 2) ~= 1 then
      return false
    end
  end
  for _, f in ipairs(files) do
    if f.kind == "untracked" then
      vim.uv.fs_unlink(root .. "/" .. f.path)
    else
      local in_head = git.sync(root, { "cat-file", "-e", "HEAD:" .. head_path(f) })
      if f.old_path then -- undo a rename: drop the new name, bring back the old
        git.sync(root, { "rm", "-f", "-q", "--", f.path })
      end
      if in_head then
        local ok, _, err = git.sync(root, { "restore", "--source=HEAD", "--staged", "--worktree", "--", head_path(f) })
        if not ok then
          notify("git restore failed: " .. err, vim.log.levels.ERROR)
        end
      else
        git.sync(root, { "rm", "-f", "-q", "--", f.path })
      end
    end
    reload_buffer(root, f.path)
  end
  return true
end

--- Commit what's staged. `cb(ok)` runs once git has finished.
function M.commit(root, message, opts, cb)
  local args = { "commit", "-F", "-" }
  if opts.amend then
    args[#args + 1] = "--amend"
  end
  git.run(root, args, { stdin = message }, function(ok, out, err)
    if ok then
      notify(vim.trim(out):match("^[^\n]*"))
    else
      local text = vim.trim(err ~= "" and err or out)
      notify("Commit failed:\n" .. text, vim.log.levels.ERROR)
    end
    cb(ok)
  end)
end

--- Run a network command (push/pull/fetch) with progress and result notifications.
function M.remote(root, verb, args, cb)
  notify(verb .. "…")
  git.run(root, args, function(ok, out, err)
    local text = vim.trim(err ~= "" and err or out)
    if ok then
      notify(verb .. " done" .. (text ~= "" and (":\n" .. text) or ""))
    else
      notify(verb .. " failed:\n" .. text, vim.log.levels.ERROR)
    end
    cb(ok)
  end)
end

return M
