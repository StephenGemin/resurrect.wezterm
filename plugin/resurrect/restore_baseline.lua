local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")
local log = require("resurrect.logging")

-- Restored panes replay their saved scrollback via inject_output, and the
-- restore's trailing "\r\n" makes the live shell print one genuinely new
-- prompt. A later save that re-captures such a pane therefore persists
-- [replay + fresh prompt] -- one extra prompt block per save->restore cycle,
-- forever. This module remembers what was replayed into each restored pane,
-- polls until that fresh prompt has painted and the pane goes quiescent, and
-- treats "a later capture still equals that snapshot" as proof the pane is
-- untouched, persisting the replay byte-identically instead of re-capturing.
-- Any content change after the snapshot falls back to a live capture. The one
-- gap: activity that both starts AND goes quiescent inside the settle window
-- (a short command run right after restore) is frozen into the snapshot and
-- then treated as idle; a later save persists the bare replay and that output
-- is lost on the next restore. Continuous activity never quiesces, times out,
-- and drops to live capture, so only briefly-active-then-idle panes are
-- exposed; the growth guard drops anything but a prompt-sized change. (OSC 133
-- semantic zones were tried first and are unreliable on wezterm 20240203: the
-- restore's own "\r\n" creates spurious Output zones under transient prompts,
-- while real command output sometimes creates none.)
local pub = {}

---@type {[integer]: {text: string, snapshot: string?}}
local _baselines = {}

-- The fresh prompt is not painted at a fixed delay after the restore's "\r\n":
-- on a cold gui-startup restore several shells spawn at once and the first
-- prompt can take many seconds to appear. A single snapshot taken too early
-- captures the replay without the prompt, so every later save mismatches and
-- captures live -- the compounding bug. Instead poll until the pane goes
-- quiescent (two identical captures) *after* it has grown past the replay,
-- then snapshot. Ceiling: SETTLE_MAX_POLLS * SETTLE_POLL_SECONDS.
local SETTLE_POLL_SECONDS = 1.0
local SETTLE_MAX_POLLS = 15

-- A settle snapshot may exceed the rendered replay by a fresh prompt block,
-- nothing more. Growth beyond this many rows means the user was already
-- active during the settle window; freezing that activity into the snapshot
-- would let a later idle save silently persist the pre-activity replay, so
-- the registration is dropped instead (normal captures from then on).
local MAX_SETTLE_GROWTH_ROWS = 8

local function count_rows(text)
	local _, n = text:gsub("\n", "")
	return n
end

-- Split newline-joined capture text into rows for diagnostic diffing only.
local function split_rows(text)
	local rows = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		rows[#rows + 1] = line
	end
	return rows
end

-- Entries for closed panes are unreachable (pane ids are never reused); drop
-- them so long-running sessions with many restores don't accumulate dead
-- scrollback copies.
local function sweep()
	local live = {}
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		for _, tab in ipairs(mux_win:tabs()) do
			for _, pane in ipairs(tab:panes()) do
				live[pane:pane_id()] = true
			end
		end
	end
	for pane_id in pairs(_baselines) do
		if not live[pane_id] then
			_baselines[pane_id] = nil
		end
	end
end

---Record the text just replayed into a restored pane. Call after
---inject_output and before the "\r\n" that triggers the fresh prompt; the
---settle snapshot is scheduled from here.
---@param pane Pane
---@param text string the exact text passed to inject_output
function pub.register(pane, text)
	sweep()
	-- Lazy require: pane_tree requires this module back, so a top-level
	-- require would be circular.
	local max_nlines = require("resurrect.pane_tree").max_nlines
	local pane_id = pane:pane_id()
	local entry = { text = text }
	_baselines[pane_id] = entry
	-- The replay as actually rendered in this pane: long lines re-wrap to the
	-- new pane's width, so the snapshot growth bound must be measured against
	-- this, not against the original text's row count.
	local ok, rendered = pcall(utils.capture_pane_text, pane, max_nlines)
	if not ok then
		_baselines[pane_id] = nil
		log.debug("register pane=%d decision=not_tracking reason=register_capture_failed", pane_id)
		return
	end
	local rendered_rows = count_rows(rendered)
	log.debug("register pane=%d bytes=%d rendered_rows=%d", pane_id, #text, rendered_rows)

	local polls = 0
	local previous ---@type string?
	local function poll()
		if _baselines[pane_id] ~= entry then
			return
		end
		polls = polls + 1
		-- pcall: the pane may have closed during the settle window.
		local snap_ok, snapshot = pcall(utils.capture_pane_text, pane, max_nlines)
		if not snap_ok then
			_baselines[pane_id] = nil
			log.debug("settle pane=%d decision=not_tracking reason=settle_capture_failed", pane_id)
			return
		end
		local snapshot_rows = count_rows(snapshot)
		local growth = snapshot_rows - rendered_rows
		local stable = snapshot == previous
		if growth > MAX_SETTLE_GROWTH_ROWS then
			-- More than a prompt block of new rows: the user was already active
			-- during the settle window. Freezing that into the snapshot would let
			-- a later idle save persist the pre-activity replay, so drop instead.
			_baselines[pane_id] = nil
			log.debug(
				"settle pane=%d decision=drop reason=growth_exceeded rendered_rows=%d snapshot_rows=%d poll=%d",
				pane_id,
				rendered_rows,
				snapshot_rows,
				polls
			)
			return
		end
		-- growth > 0 gates out the pre-prompt frames (snapshot still equals the
		-- replay): stability alone would settle on a replay-only capture that a
		-- later save then mismatches. Requiring the prompt to have painted AND
		-- the capture to have held for a full poll interval lands the snapshot on
		-- [replay + fresh prompt], which an idle save matches byte-for-byte.
		if growth > 0 and stable then
			entry.snapshot = snapshot
			log.debug(
				"settle pane=%d decision=settled rows=%d poll=%d reason=idle_will_persist",
				pane_id,
				snapshot_rows,
				polls
			)
			return
		end
		previous = snapshot
		if polls >= SETTLE_MAX_POLLS then
			-- Never quiesced within the ceiling. Drop rather than snapshot a
			-- still-moving pane: no snapshot means later saves capture live (this
			-- cycle may bake one prompt block, but nothing stale is persisted).
			_baselines[pane_id] = nil
			log.debug(
				"settle pane=%d decision=drop reason=settle_timeout rows=%d poll=%d",
				pane_id,
				snapshot_rows,
				polls
			)
			return
		end
		wezterm.time.call_after(SETTLE_POLL_SECONDS, poll)
	end
	wezterm.time.call_after(SETTLE_POLL_SECONDS, poll)
end

---Decide what to persist for a pane given its freshly captured content.
---Returns the originally replayed text when the capture proves the pane is
---untouched since restore (byte-identical to the settle snapshot); otherwise
---returns the capture. A mismatch drops the registration: the pane has seen
---real activity, and live captures are the truth from there on (repeated
---captures of a live pane don't compound).
---@param pane Pane
---@param captured string the pane's current content as captured by pane_tree
---@return string
function pub.text_to_persist(pane, captured)
	local entry = _baselines[pane:pane_id()]
	if not entry then
		return captured
	end
	local pane_id = pane:pane_id()
	if not entry.snapshot then
		log.debug("persist pane=%d decision=capture_live reason=saved_before_settle", pane_id)
		return captured
	end
	if captured == entry.snapshot then
		log.debug("persist pane=%d decision=persist_replay", pane_id)
		return entry.text
	end
	_baselines[pane_id] = nil
	-- The mismatch has two opposite causes that this branch cannot otherwise
	-- tell apart: the settle snapshot was taken before the fresh prompt painted
	-- (captured_rows > snapshot_rows -> the fix is a longer/poll-until-quiescent
	-- settle) versus a dynamic prompt segment repainting between settle and save
	-- (equal row counts, bytes differ in one row -> a settle delay never helps).
	-- The first differing row's index and content discriminate the two.
	if log.is_debug_enabled() then
		local cap_rows = split_rows(captured)
		local snap_rows = split_rows(entry.snapshot)
		local first_diff = 0
		for i = 1, math.max(#cap_rows, #snap_rows) do
			if cap_rows[i] ~= snap_rows[i] then
				first_diff = i
				break
			end
		end
		local function clip(s)
			s = s or "<none>"
			return #s > 120 and (s:sub(1, 120) .. "...") or s
		end
		log.debug(
			"persist pane=%d mismatch captured_rows=%d snapshot_rows=%d first_diff_row=%d cap=%q snap=%q",
			pane_id,
			#cap_rows,
			#snap_rows,
			first_diff,
			clip(cap_rows[first_diff]),
			clip(snap_rows[first_diff])
		)
	end
	log.debug("persist pane=%d decision=capture_live reason=changed_since_restore", pane_id)
	return captured
end

return pub
