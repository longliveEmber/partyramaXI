local M = {};
local floor, max = math.floor, math.max;

M.N = 120;            -- rolling average window (frames)
M.BUCKET = 0.5;       -- seconds per max bucket
M.NB = 10;            -- buckets -> max over the last 5 s

-- Section keys (array indexes, so the hot path never hashes strings)
M.TOTAL, M.UPDATE, M.DRAW, M.SCAN, M.LAYOUT, M.ROWS, M.FX, M.HEADER, M.CONFIG = 1, 2, 3, 4, 5, 6, 7, 8, 9;
M.NK = 9;
M.LABEL = { 'total', 'update', 'draw', 'scan', 'layout', 'draw rows', 'glow/texture', 'header', 'config window' };

M.on = false;         -- sampling
M.overlay = false;    -- overlay window shown
M.timer_name = 'none';
M.now = nil;          -- function () -> milliseconds (set by M.pick_timer)

local cur, ring, sum, bmax = {}, {}, {}, {};
for k = 1, M.NK do
    cur[k], sum[k], ring[k], bmax[k] = 0, 0, {}, {};
    for i = 1, M.N do ring[k][i] = 0; end
    for b = 1, M.NB do bmax[k][b] = 0; end
end
M.cur = cur;
local idx, filled, frames, bucket_id, bucket = 0, 0, 0, -1, 1;
local config_frames = 0;   -- frames in the window where the config window was open

--[[ ------------------------------------------------------------------ timer ]]
local function try_ffi_qpc()
    local okj, jit_ = pcall(require, 'jit');
    if (not okj or type(jit_) ~= 'table' or jit_.os ~= 'Windows') then return nil, 'not Windows'; end
    local okf, ffi = pcall(require, 'ffi');
    if (not okf) then return nil, 'no ffi'; end
    -- private names via asm redirection, so any other declaration of QueryPerformanceCounter
    -- (another addon or Ashita lib, maybe with LARGE_INTEGER*) can never conflict with ours
    pcall(ffi.cdef, [[
        typedef union { int64_t q; struct { uint32_t lo, hi; } p; } rxi_li_t;
        int __stdcall rxi_qpc(rxi_li_t *c) __asm__("QueryPerformanceCounter");
        int __stdcall rxi_qpf(rxi_li_t *f) __asm__("QueryPerformanceFrequency");
    ]]);
    local ok, qpc, qpf = pcall(function () return ffi.C.rxi_qpc, ffi.C.rxi_qpf; end);
    if (not ok or qpc == nil) then return nil, 'QueryPerformanceCounter not found'; end
    local buf = ffi.new('rxi_li_t[1]');
    if (qpf(buf) == 0) then return nil, 'QueryPerformanceFrequency failed'; end
    local freq = buf[0].p.hi * 4294967296 + buf[0].p.lo;
    if (freq <= 0) then return nil, 'bad frequency'; end
    if (qpc(buf) == 0) then return nil, 'QueryPerformanceCounter failed'; end
    local e = buf[0].p;
    local base = e.hi * 4294967296 + e.lo;
    local k = 1000 / freq;
    return function ()
        qpc(buf);
        return ((e.hi * 4294967296 + e.lo) - base) * k;
    end, ('QueryPerformanceCounter via ffi (%.0f MHz)'):format(freq / 1e6);
end

local function li(v)   -- LargeInteger table or a plain number
    if (type(v) == 'number') then return v; end
    if (type(v) == 'table' or type(v) == 'userdata') then
        local q = v.q or v.quad_part;
        if (type(q) == 'number') then return q; end
        local h, l = v.h or v.high_part, v.l or v.low_part;
        if (type(h) == 'number' and type(l) == 'number') then return h * 4294967296 + (l % 4294967296); end
    end
    return nil;
end

local function try_ashita_qpc()
    local at = rawget(_G, 'ashita'); at = (type(at) == 'table') and at.time or nil;
    if (type(at) ~= 'table' or type(at.qpc) ~= 'function' or type(at.qpf) ~= 'function') then return nil, 'no ashita.time.qpc'; end
    local ok1, f = pcall(at.qpf); local ok2, c = pcall(at.qpc);
    f, c = ok1 and li(f), ok2 and li(c);
    if (not f or not c or f <= 0) then return nil, 'ashita.time.qpc unusable'; end
    local qpc, base, k = at.qpc, c, 1000 / f;
    return function () return (li(qpc()) - base) * k; end, 'ashita.time.qpc';
end

-- Picks the best timer once. Returns its name. `override` (tests) is a function -> ms.
function M.pick_timer(override, name)
    if (override ~= nil) then M.now, M.timer_name = override, name or 'test timer'; return M.timer_name; end
    if (M.now ~= nil) then return M.timer_name; end
    local f, n = try_ffi_qpc();
    if (f == nil) then f, n = try_ashita_qpc(); end
    if (f == nil) then
        local c = os.clock;
        local base = c();
        f, n = function () return (c() - base) * 1000; end, 'os.clock (coarse, ~1 ms steps on Windows)';
    end
    M.now, M.timer_name = f, n;
    return n;
end

--[[ ------------------------------------------------------------------ sampling ]]
function M.reset()
    for k = 1, M.NK do
        cur[k], sum[k] = 0, 0;
        local r, b = ring[k], bmax[k];
        for i = 1, M.N do r[i] = 0; end
        for i = 1, M.NB do b[i] = 0; end
    end
    idx, filled, frames, bucket_id, bucket, config_frames = 0, 0, 0, -1, 1, 0;
    M.text_at = -1;
end

function M.start() M.pick_timer(); M.reset(); M.on = true; end
function M.stop() M.on = false; M.overlay = false; end

-- End of a sampled frame: move this frame's section times into the rings. `t` = frame clock (s).
function M.commit(t, config_open)
    idx = idx + 1; if (idx > M.N) then idx = 1; end
    if (filled < M.N) then filled = filled + 1; end
    frames = frames + 1;
    local bid = floor(t / M.BUCKET);
    if (bid ~= bucket_id) then
        -- advance (clearing every bucket we skipped, up to all of them)
        local steps = (bucket_id < 0) and M.NB or (bid - bucket_id);
        if (steps < 0 or steps > M.NB) then steps = M.NB; end
        for _ = 1, steps do
            bucket = bucket + 1; if (bucket > M.NB) then bucket = 1; end
            for k = 1, M.NK do bmax[k][bucket] = 0; end
        end
        bucket_id = bid;
    end
    local resum = (idx == 1);   -- re-add once per lap so float drift can't build up
    for k = 1, M.NK do
        local v = cur[k];
        local r = ring[k];
        sum[k] = sum[k] - r[idx] + v;
        r[idx] = v;
        local b = bmax[k];
        if (v > b[bucket]) then b[bucket] = v; end
        cur[k] = 0;
        if (resum) then local s = 0; for i = 1, M.N do s = s + r[i]; end sum[k] = s; end
    end
    if (config_open) then config_frames = config_frames + 1; end
end

function M.avg(k) return (filled > 0) and (sum[k] / filled) or 0; end
function M.max5(k) local b, m = bmax[k], 0; for i = 1, M.NB do if (b[i] > m) then m = b[i]; end end return m; end
function M.frames() return frames; end
function M.window() return filled; end
function M.config_frames() return config_frames; end

--[[ ------------------------------------------------------------------ text ]]
local fmt = string.format;
M.text_at = -1;
M.text = '';
-- Overlay line, re-formatted at most twice a second (interned when the numbers repeat).
function M.overlay_text(t)
    if (M.text_at < 0 or t - M.text_at >= 0.5 or t < M.text_at) then
        M.text_at = t;
        M.text = fmt('RecastXI %.3f ms/frame avg (update %.3f, draw %.3f) | max %.3f ms (5 s) | %d frames',
            M.avg(M.TOTAL), M.avg(M.UPDATE), M.avg(M.DRAW), M.max5(M.TOTAL), frames);
    end
    return M.text;
end

-- One chat line for /rxi perf report.
function M.report_line(config_open)
    if (frames == 0) then return nil; end
    local cfg = (config_open or config_frames > 0) and fmt('config window %.3f', M.avg(M.CONFIG)) or 'config window closed';
    return fmt('avg %.3f ms/frame (update %.3f, draw %.3f), max %.3f ms in the last 5 s, %d frames sampled (avg over %d) | scan %.3f, layout %.3f, draw rows %.3f, glow/texture %.3f, header %.3f, %s | timer: %s',
        M.avg(M.TOTAL), M.avg(M.UPDATE), M.avg(M.DRAW), M.max5(M.TOTAL), frames, filled,
        M.avg(M.SCAN), M.avg(M.LAYOUT), M.avg(M.ROWS), M.avg(M.FX), M.avg(M.HEADER), cfg, M.timer_name);
end

return M;
