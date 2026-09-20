-- A stand-in for mpv's Lua environment, enough to run laev's tracker for a
-- whole playback: register handlers, tick the timers, fire the events.
-- Errors are deliberately left to propagate — mpv kills a script whose
-- handler raises, and that silence is exactly what this harness exists to
-- turn into a failing test.
local script, posfile, tracksfile, playedfile, mode = ...

package.preload["mp.options"] = function()
  return {
    read_options = function(opts, _name)
      opts.file, opts.tracks, opts.played = posfile, tracksfile, playedfile
    end
  }
end

local events, timers, timeouts, props = {}, {}, {}, {}

mp = {
  register_event = function(name, fn)
    events[name] = events[name] or {}
    table.insert(events[name], fn)
  end,
  observe_property = function(_name, _type, _fn) end,
  add_periodic_timer = function(period, fn) timers[period] = fn end,
  add_timeout = function(_secs, fn) table.insert(timeouts, fn) end,
  get_property_number = function(key) return props[key] end,
  get_property = function(key) return props[key] end,
}

local function fire(name, arg)
  for _, fn in ipairs(events[name] or {}) do fn(arg) end
end

dofile(script)

local DURATION = 6000
props.duration = DURATION
fire("file-loaded")
for _, fn in ipairs(timeouts) do fn() end   -- the 2s settle window

-- One tick per second, like mpv: the tracker tells playback from seeking by
-- how far the playhead moved between samples, so the step size is the test.
local function tick(pos)
  props["time-pos"] = pos
  timers[1]()
  if pos % 5 == 0 then timers[5]() end
end

if mode == "seek" then
  -- watch a minute, jump an hour, watch another minute
  for pos = 1, 60 do tick(pos) end
  tick(3660)
  for pos = 3661, 3720 do tick(pos) end
  fire("shutdown")
else
  -- straight through to the end, then mpv's own end-of-file event
  for pos = 1, DURATION do tick(pos) end
  fire("end-file", { reason = "eof" })
  fire("shutdown")
end
