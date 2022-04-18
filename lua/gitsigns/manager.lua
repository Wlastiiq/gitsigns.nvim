local void = require('gitsigns.async').void
local awrap = require('gitsigns.async').wrap

local gs_cache = require('gitsigns.cache')
local CacheEntry = gs_cache.CacheEntry
local cache = gs_cache.cache

local Signs = require('gitsigns.signs')

local Status = require("gitsigns.status")

local debounce_trailing = require('gitsigns.debounce').debounce_trailing
local throttle_by_id = require('gitsigns.debounce').throttle_by_id
local gs_debug = require("gitsigns.debug")
local dprint = gs_debug.dprint
local dprintf = gs_debug.dprintf
local eprint = gs_debug.eprint
local subprocess = require('gitsigns.subprocess')
local util = require('gitsigns.util')
local run_diff = require('gitsigns.diff')

local gs_hunks = require("gitsigns.hunks")
local Hunk = gs_hunks.Hunk

local config = require('gitsigns.config').config

local api = vim.api

local signs
local signs_staged

local M = {}












local schedule_if_buf_valid = function(buf, cb)
   vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
         cb()
      end
   end)
end

local scheduler_if_buf_valid = awrap(schedule_if_buf_valid, 2)

function M.apply_win_signs(bufnr, hunks, hunks2, top, bot, clear)
   for _, hs in ipairs({
         { hunks, signs },
         { hunks2, signs_staged },
      }) do
      local h, s = hs[1], hs[2]

      if clear then
         s:remove(bufnr)
      end





      for i, hunk in ipairs(h or {}) do
         if clear and i == 1 or
            top <= hunk.vend and bot >= hunk.start then
            s:schedule(bufnr, gs_hunks.calc_signs(hunk))
         end
         if hunk.start > bot then
            break
         end
      end

      s:draw(bufnr, top, bot)
   end
end

M.on_lines = function(buf, first, _, last_new)
   local bcache = cache[buf]
   if not bcache then
      dprint('Cache for buffer was nil. Detaching')
      return true
   end



   if bcache.hunks and signs:need_redraw(buf, first, last_new) then

      bcache.hunks = nil
      bcache.hunks2 = nil
   end

   M.update_debounced(buf, cache[buf])
end

local ns = api.nvim_create_namespace('gitsigns')

M.apply_word_diff = function(bufnr, row)
   if not cache[bufnr] or not cache[bufnr].hunks then
      return
   end

   local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
   if not line then

      return
   end

   local lnum = row + 1

   local hunk = gs_hunks.find_hunk(lnum, cache[bufnr].hunks)
   if not hunk then

      return
   end

   if hunk.added.count ~= hunk.removed.count then

      return
   end

   local pos = lnum - hunk.start + 1

   local added_line = hunk.added.lines[pos]
   local removed_line = hunk.removed.lines[pos]

   local _, added_regions = require('gitsigns.diff_int').run_word_diff({ removed_line }, { added_line })

   local cols = #line

   for _, region in ipairs(added_regions) do
      local rtype, scol, ecol = region[2], region[3], region[4]
      if scol <= cols then
         if ecol > cols then
            ecol = cols
         elseif ecol == scol then

            ecol = scol + 1
         end
         api.nvim_buf_set_extmark(bufnr, ns, row, scol - 1, {
            end_col = ecol - 1,
            hl_group = rtype == 'add' and 'GitSignsAddLnInline' or
            rtype == 'change' and 'GitSignsChangeLnInline' or
            'GitSignsDeleteLnInline',
            ephemeral = true,
            priority = 1000,
         })
         api.nvim__buf_redraw_range(bufnr, row, row + 1)
      end
   end
end

local ns_rm = api.nvim_create_namespace('gitsigns_removed')

local VIRT_LINE_LEN = 300

local function clear_deleted(bufnr)
   local marks = api.nvim_buf_get_extmarks(bufnr, ns_rm, 0, -1, {})
   for _, mark in ipairs(marks) do
      api.nvim_buf_del_extmark(bufnr, ns_rm, mark[1])
   end
end

local function show_deleted(bufnr)
   local bcache = cache[bufnr]

   clear_deleted(bufnr)

   if not config.show_deleted then
      return
   end

   for _, hunk in ipairs(bcache.hunks) do
      local virt_lines = {}
      local do_word_diff = config.word_diff and #hunk.removed.lines == #hunk.added.lines

      for i, line in ipairs(hunk.removed.lines) do
         local vline = {}
         local last_ecol = 1

         if do_word_diff then
            local regions = require('gitsigns.diff_int').run_word_diff(
            { hunk.removed.lines[i] }, { hunk.added.lines[i] })

            for _, region in ipairs(regions) do
               local rline, scol, ecol = region[1], region[3], region[4]
               if rline > 1 then
                  break
               end
               vline[#vline + 1] = { line:sub(last_ecol, scol - 1), 'GitsignsDeleteVirtLn' }
               vline[#vline + 1] = { line:sub(scol, ecol - 1), 'GitsignsDeleteVirtLnInline' }
               last_ecol = ecol
            end
         end

         if #line > 0 then
            vline[#vline + 1] = { line:sub(last_ecol, -1), 'GitsignsDeleteVirtLn' }
         end


         local padding = string.rep(' ', VIRT_LINE_LEN - #line)
         vline[#vline + 1] = { padding, 'GitsignsDeleteVirtLn' }

         virt_lines[i] = vline
      end

      api.nvim_buf_set_extmark(bufnr, ns_rm, hunk.start - 1, -1, {
         virt_lines = virt_lines,
         virt_lines_above = hunk.type ~= 'delete',
      })
   end
end

local function compare_new(a, b)
   if a.added.start ~= b.added.start then
      return false
   end

   if a.added.count ~= b.added.count then
      return false
   end

   local a_lines = a.added.lines
   local b_lines = b.added.lines

   for i = 1, #a_lines do
      if a_lines[i] ~= b_lines[i] then
         return false
      end
   end

   return true
end
























local function filter_common(a, b)
   if not a and not b then return end
   a, b = a or {}, b or {}
   local max = math.max(#a, #b)

   local ai = 1
   local bi = 1

   local r = {}

   for _ = 1, max do
      local ah, bh = a[ai], b[bi]
      if not ah then

         break
      end
      if not bh then

         for n = ai, #a do
            r[#r + 1] = a[n]
         end
         break
      end
      if ah.start > bh.start then

         bi = bi + 1
      elseif ah.start < bh.start then

         r[#r + 1] = ah
         ai = ai + 1
      else



         if not compare_new(ah, bh) then
            r[#r + 1] = ah
         end
         ai = ai + 1
         bi = bi + 1
      end
   end

   return r
end

local update_cnt = 0





M.update = throttle_by_id(function(bufnr, bcache)
   local __FUNC__ = 'update'
   bcache = bcache or cache[bufnr]
   if not bcache then
      eprint('Cache for buffer ' .. bufnr .. ' was nil')
      return
   end
   local old_hunks = bcache.hunks
   bcache.hunks = nil

   scheduler_if_buf_valid(bufnr)
   local buftext = util.buf_lines(bufnr)
   local git_obj = bcache.git_obj

   if not bcache.compare_text or config._refresh_staged_on_update then
      bcache.compare_text = git_obj:get_show_text(bcache:get_compare_rev())
   end

   if not bcache.compare_text2 or config._refresh_staged_on_update then
      bcache.compare_text2 = git_obj:get_show_text('HEAD')
   end

   bcache.hunks = run_diff(bcache.compare_text, buftext)
   local hunks2 = run_diff(bcache.compare_text2, buftext)
   bcache.hunks2 = filter_common(hunks2, bcache.hunks)

   scheduler_if_buf_valid(bufnr)
   if gs_hunks.compare_heads(bcache.hunks, old_hunks) then


      M.apply_win_signs(bufnr, bcache.hunks, bcache.hunks2, vim.fn.line('w0'), vim.fn.line('w$'), true)

      show_deleted(bufnr)
   end

   local summary = gs_hunks.get_summary(bcache.hunks)
   summary.head = git_obj.repo.abbrev_head
   Status:update(bufnr, summary)

   update_cnt = update_cnt + 1

   dprintf('updates: %s, jobs: %s', update_cnt, subprocess.job_cnt)
end)

M.detach = function(bufnr, keep_signs)
   if not keep_signs then
      signs:remove(bufnr)
   end
end

M.setup = function()
   signs = Signs.new(config.signs, false)
   signs_staged = Signs.new(config.signs_staged, false, 'staged')
   M.update_debounced = debounce_trailing(config.update_debounce, void(M.update))
end

return M
