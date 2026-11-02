-- PartyramaXI default settings (saved per character by Ashita's settings library).
local T = rawget(_G, 'T') or function (t) return t end

local D = T{
    enabled = true,                 -- hide the windows ticked below
    windows = T{
        party     = true,
        alliance1 = true,
        alliance2 = true,
        target    = false,          -- shown by default: the game's own arrows stay as they are
        castinfo  = false,          -- the spell / ability info window (MP cost, recast)
    },
    alias_hideparty = false,        -- also answer /hideparty (leave off if the original is loaded)
    layout_w = 0, layout_h = 0,     -- 2.13.3: the screen the window positions were made on (pxibase: 3840 x 2160)
    catch_first = true,             -- hide a new target window during the game's drawing on its first frame (see pxiwin catch_target)

    arrow = T{
        when        = 'always',     -- fixed since 2.6 (was: 'hidden' = only while the target window is hidden)
        mode        = 'native',     -- 'native' (where the game puts its arrow) | 'entity' (over the character) | 'off'
        mode_on     = 'native',       -- the position to go back to when the Pointer tab's Enable button turns arrows on again
        style       = 'triangle',   -- 'triangle' | 'chevron' | 'crystal' | 'png:<file in arrows/>'
        png_rotation = 0,           -- turn PNG arrows 0/90/180/270 degrees (they should point down)
        png_tint    = true,         -- multiply PNG arrows by the arrow colors
        size        = 18,
        show_main   = true,         -- arrow on the target you hold, not just the sub-target cursor
        main_color  = T{ 1.00, 1.00, 1.00, 1.00 },
        sub_color   = T{ 0.99, 0.82, 0.09, 1.00 },
        outline     = true,
        outline_color = T{ 0.00, 0.00, 0.00, 0.85 },
        outline_thickness = 2,
        pulse       = true,
        bob         = true,
        bob_amount  = 6,
        anim_speed  = 1.5,          -- cycles per second
        head_height = 2.4,          -- yalms above the entity's position (2.0-5.0); 2.9.2: only until its model has loaded
        head_gap = 0.4,             -- 2.9.2: over the character: yalms above the top of its head (the head bone)
        flip_height = false,        -- use if arrows appear below characters
        native_dx   = 0,            -- nudge for the native-position source (pixels)
        native_dy   = 0,
        hide_in_events = true,
        sheen       = true,         -- a sweep of light across the arrow now and then (built-in shapes)
        sheen_min   = 2,            -- seconds between sweeps: a random time from min to max (fixed 2-8 since 2.6)
        sheen_max   = 8,
        sheen_strength = 0.6,
        cfg260      = false,        -- internal: the 2.6 pointer defaults have been applied once
    },

    -- enemy info next to the pointer (monsters only). dx / dy are pixels from the pointer tip.
    info = T{
        enabled   = true,
        show_sub  = true,           -- also for the monster the sub-target cursor is on
        apart     = 10,             -- 1.0.3: px kept between the sub-target's card and the main target's (it moves off)
        npc_color = T{ 0.55, 0.75, 1.00, 1.00 },
        -- 2.9.0: what each kind of target gets (Enemies / Players / NPCs tabs). abs = drawn at a fixed spot on the
        -- screen (ax, ay = where the pointer tip would be) instead of over the target. Players' and NPCs' elements have
        -- their own offsets (off); an enemy's are the elements' own dx / dy.
        names_on = false,            -- 2.12.0: the game's /names as last typed (on = the game shows names over characters)
        names_cfg = 0, names_cfg_on = 0,   -- 2.13.2: the game setting /names changes (learned; 0 = not yet) and its "shown" value
        kinds = T{
            mob = T{ enabled = true, hide_events = true, name = true, hp = true, dist = true, icons = true, abs = false, ax = 0, ay = 0 },
            -- 2.9.1 self: also your own character. 2.12.0 name_names: no name while /names is on. (2.13.3: these two notes
            -- had swallowed hp, dist, icons, abs, ax and ay, so players had no defaults for them)
            -- 2.13.4 badges: the linkshell pearl and the game's name icons (LFP, AWAY, ANON...) over the name, badge_size px high
            pc  = T{ enabled = true, self = false, hide_events = true, name = true, name_names = false, hp = true, dist = true, icons = true, abs = false, ax = 0, ay = 0,
                     badges = true, badge_size = 16, badge_new = true,
                     off = T{ name = T{ dx = 0, dy = -66 }, bar = T{ dx = 0, dy = -52 }, dist = T{ dx = 56, dy = -52 }, fx = T{ dx = 0, dy = -98 }, pct = T{ dx = 0, dy = 0 } } },
            npc = T{ enabled = true, hide_events = true, name = true, name_names = false, hp = false, dist = true, icons = true, abs = false, ax = 0, ay = 0,
                     off = T{ name = T{ dx = 0, dy = -66 }, bar = T{ dx = 0, dy = -52 }, dist = T{ dx = 56, dy = -52 }, fx = T{ dx = 0, dy = -98 }, pct = T{ dx = 0, dy = 0 } } },
        },
        fade_when  = 'either',      -- battle fade trigger: me | target | either
        fade_delay = 3,             -- seconds in battle before the fade starts
        dock       = true,          -- 2.12.0: target off the screen: its bar docks above the party list (party list's panel)
        dock_pin   = false,         -- 2.12.2: the current target always shows docked there, on screen or not
        dock_simple = true,         -- 2.12.3: the docked card shows only name, health bar and distance
        dock_fx = true,             -- 1.0.0: effects on the docked card, drawn like the party list's status icons
        dock_fx_size = 32,          -- 1.0.2: ...at their own size (px), wrapped to stay inside the card
        dock_fx_timers = true,      -- 1.0.2: ...with their own countdown switch (the countdown's look follows the party list)
        dock_float = false,         -- 2.12.7: pinned: the bar also stays over the target (both shown)
        glide_x    = 0,             -- in battle every element eases this far across (0 = off)
        glide_ease = 'smooth',      -- how the glide moves out: smooth | smoother | ease_in | back | bounce | spring (the way back plays it in reverse)
        glide_y    = 0,             -- ...and this far up (-) / down (+) from where it normally sits
        fade_in    = 0.28,          -- seconds the info fades in when a target is picked
        fade_out   = 0.28,          -- seconds it fades out when the target dies
        snap190    = false,         -- internal: the 1.9 faster-fade migration has run
        glide_hold = 6,             -- seconds the in-battle position is kept after the fight (aggro) seems to end
        fade_time  = 0.8,           -- seconds the fade takes
        reuse_name = true,          -- show the difficulty of an already-checked monster for others with the same name (dimmed)
        auto_check = false,         -- send /check for you the first time you target a monster (off: you /check yourself)
        text_size = 1.0,
        font      = 'Default (Ashita)',   -- a name from the settings window list (Windows fonts + addons\partyramaxi\fonts)
        bold      = false, italic = false,
        shadow    = true,           -- dark shadow behind the text so it reads on any background
        outline   = false,          -- thin dark outline around the letters
        outline_w = 1, outline_color = T{ 0.00, 0.00, 0.00, 0.95 },   -- its thickness (1-3 px) and color
        hide_in_events = true,
        name  = T{ z = 2, show = true, color = T{ 1.00, 1.00, 1.00, 1.00 }, scale = 1.0, fade = false, fade_alpha = 0.2, dx = 0, dy = -66 },
        bar   = T{ z = 1, show = true, width = 100, height = 9,
                   fill = T{ 0.86, 0.22, 0.22, 1.00 }, back = T{ 0.00, 0.00, 0.00, 0.65 },
                   border = true, border_color = T{ 0.00, 0.00, 0.00, 0.90 },
                   by_hp = false,   -- color the bar green > yellow > red as health drops
                   fade = false, fade_alpha = 0.2,   -- fade out during battle (see fade_when)
                   rounding = 2,    -- corner radius in pixels (0 = square, half the height = pill)
                   border_width = 1, outline_width = 0, outline_color = T{ 1.00, 1.00, 1.00, 0.35 },   -- from the inside out: bar color, outline (0-5 px), border (1-8 px)
                   sheen = true, comet = 'once', comet_color = T{ 1.00, 1.00, 1.00, 1 }, comet_speed = 1.0,   -- one sheen / comet pass when the bar refills to 100%
                   gloss = 'glossy', gloss_strength = 0.5,   -- none | gradient | glossy | shine
                   ticks = false, tick_len = 5,   -- light marks at 25 / 50 / 75 %, this many pixels long
                   percent = false, percent_scale = 0.8,   -- the health number inside the bar, and its size
                   pct_mob = true, pct_pc = true, pct_npc = true, pct_dx = 0, pct_dy = 0,   -- 2.7.0: (with percent on) which targets show it, and where
                   trail = false, trail_color = T{ 1.00, 0.85, 0.30, 0.90 },   -- recent damage drains out slowly
                   dx = 0, dy = -52 },
        level = T{ z = 3, show = true, db = true,   -- db (2.8.0): LandSandBoat's level range until you /check
                    color = T{ 1.00, 0.92, 0.55, 1.00 }, scale = 1.0, fade = false, fade_alpha = 0.2, unknown = true, dx = -4, dy = -38 },
        check = T{ z = 4, show = true, color = T{ 1.00, 1.00, 1.00, 1.00 }, by_diff = true, scale = 1.0, fade = false, fade_alpha = 0.2, style = 'short', unknown = true, dx = 18, dy = -38 },   -- centred on this point

        -- evasion / defense of the monster (from the check reply): Eva / Def with an arrow or a word
        defev = T{
            z = 5, show = true,
            arrows = true,           -- false: the words High / Low
            show_normal = false,     -- also show "normal"
            color_high = T{ 1.00, 0.35, 0.30, 1.00 },   -- high is bad for you: red
            color_low  = T{ 0.45, 0.90, 0.50, 1.00 },   -- low is good for you: green
            color_label = T{ 0.85, 0.85, 0.85, 1.00 },
            scale = 0.9, fade = false, fade_alpha = 0.2,
            dx = 0, dy = -24,
        },

        -- distance from you to the target, in yalms
        dist = T{ z = 7, show = true, format = 'short', color = T{ 0.85, 0.90, 1.00, 1.00 }, scale = 0.85, fade = false, fade_alpha = 0.2,
                  far = true, far_at = 21.0, far_color = T{ 1.00, 0.55, 0.40, 1.00 },   -- another color beyond this distance (spell range ~21)
                  dx = 56, dy = -52 },                                                   -- left end of the text, by default just right of the bar

        -- status effects on the target (learned from spell packets, see pxifx.lua)
        fx = T{
            enabled = true, z = 6,
            fade = false, fade_alpha = 0.2,
            mine_only = false,       -- only effects you applied
            show_unknown = true,     -- also effects with no known duration (no countdown)
            sort = 'soonest',
            size = 22, spacing = 2, per_row = 8,
            align = 'center', rows_up = false,
            dx = 0, dy = -98,        -- centre of the first row, from the pointer tip
            text = 'below', text_scale = 0.8, text_color = T{ 1.00, 1.00, 1.00, 1.00 },
            warn_secs = 5, warn_color = T{ 1.00, 0.35, 0.30, 1.00 },
            ring = 'ring', ring_shape = 'circle', ring_width = 2, ring_pad = 3, flash = true, flash_speed = 2.5, ring_color = T{ 0.55, 0.95, 0.60, 1.00 },
            flash_min = 0.6,         -- the icon dips to this opacity at the dimmest point of the warning flash (1 = no dip)
            ended_alpha = 0.5,       -- opacity of an effect that has worn off; it stays this steady for 3 s, then disappears
            pack = '', pack2 = '',              -- icon pack and fallback pack: sub-folders of addons\partyramaxi\icons\packs\ ('' = none)
            slide = true,            -- icons slide into the gap when an effect wears off
            duration_pct = 100,      -- scale every known duration (gear, server rules)
        },

        icon_style = 'glossy',      -- monster info (2.10.1: weaknesses have weak.icon_style), element and Recasts category pictures: glossy | jewel (2.9.0) | painted (elements) | flat | glyph | contrast | glass (2.10.0)
        -- 2.8.0: the rest of MobDB from LandSandBoat's monster data (pximob.lua): badges for NM, aggressive, links, true
        -- sight / sound, how it detects you, charmable, then jobs / level / respawn as text. Hover for the whole card.
        mob = T{
            show = true, z = 9,
            fade = false, fade_alpha = 0.2,
            nm = true, aggro = true, link = true, truesight = true, senses = true, charm = false,
            text = true, show_jobs = true, show_level = false, show_respawn = false,   -- the line after the badges
            text_scale = 0.8, text_color = T{ 0.90, 0.90, 0.90, 1.00 },
            size = 16, spacing = 2, align = 'center',
            dx = 0, dy = -146,       -- centre of the row, from the pointer tip (above the weakness icons)
            tooltip = true,          -- hover for everything: family, level, job, detection, respawn, weaknesses, drops, steal, spells
            card_scale = 1.0,        -- 2.9.0: text size of that card (drawn in front of everything)
        },
        -- 2.7.7: weaknesses / resistances / immunities like MobDB, from LandSandBoat's monster data (pxiweak.lua)
        weak = T{
            icon_style = 'glossy',   -- 2.10.1: the weakness pictures' own style (same choices as icon_style above)
            show = true, z = 8,
            fade = false, fade_alpha = 0.2,
            elements = true,         -- element icons
            physical = true,         -- slashing / piercing / blunt / hand-to-hand / magic damage taken
            immune = true,           -- status effects it is immune to (crossed out)
            weak = true,             -- show weaknesses
            weak_best = true,        -- of the elements it is weak to, only the ones it is weakest to
            resist = true,           -- show resistances
            source = 'auto',         -- 2.9.4: 'auto' = MobDB's numbers when its addon has the monster, else LandSandBoat; 'lsb'
            status = true,           -- 2.9.3: status effects it is weak to / resists (immune ones are 'immune')
            resist_rank = 1,         -- an element / effect counts as resisted from this resistance rank (1-10). 2.9.3: was 4
            rank293 = false,         -- internal: the 2.9.3 move of Resists from rank 4 -> 1 has run
            marks = 'arrows',        -- 2.9.3: corner marks: 'arrows' or 'percent' (+/- %)
            pct_scale = 1,           -- size of the +/- % numbers
            resist_alpha = 0.8,      -- opacity of resisted / nullified icons
            size = 16, spacing = 2, per_row = 10,
            align = 'center', rows_up = false,
            dx = 0, dy = -126,       -- centre of the first row, from the pointer tip
            tooltip = true,          -- hover the row for the details in words
            weak_color   = T{ 0.40, 0.95, 0.45, 1.00 },
            resist_color = T{ 1.00, 0.40, 0.35, 1.00 },
            null_color   = T{ 1.00, 0.22, 0.18, 1.00 },
        },
    },

    -- action buffer (pxibuffer.lua): a spell / ability used up to 'window' s before its recast is ready is sent when ready
    buffer = T{ enabled = true, window = 0.30, delay = 0.25, messages = false },   -- delay: extra wait once the recast reads ready. 2.9.1: fixed (no options)

    -- the party list (see pxilist.lua). Theme presets (pxilisttheme.lua) fill in the colors and shapes below.
    list = T{
        enabled   = false,
        alliance  = true,           -- also show alliance members
        -- 2.7.6: health bars over members' heads, sized by distance from the camera (pxiover.lua)
        -- 2.7.8: anchor 'head' = head_gap yalms over the top of the head (skeleton, where nameplates sit); 'feet' = head yalms over the feet
        over = T{ enabled = false, self = false, alliance = false, anchor = 'head', head_gap = 0.3, head = 2.4,
            aggro = 'focus', aggro_style = 'both', aggro_color = T{ 1.00, 0.30, 0.22, 1.00 },   -- 2.8.1: mark whom the enemy is after (focus = your enemy, any = every monster)
            width = 60, height = 6, rounding = 2,
            -- 2.10.1: max_px = the largest width in px (max_scale follows it); anchor is always 'head' ('head' = the fallback height)
            ref = 8, min_scale = 0.4, max_scale = 1.5, max_px = 90, max_dist = 40, alpha = 1, mp = false, mp_height = 3, back = T{ 0, 0, 0, 0.60 },
            hp_look = false, hp_num = false,   -- 2.9.0: the party list's Health bar look (finish, border, trail, sheen) and its number
            dx = 0, dy = 0, num_scale = 1, num_dx = 0, num_dy = 0,
            num_fmt = 'list' },      -- 2.9.2: list = the HP tab's format | current | percent | both
        -- 2.9.2: bars over members per job: over_jobs[<JOB>] = a copy of 'over' for that job (2.10.0: always on; a job
        -- without its own copy keeps whatever the last job used)
        over_jobs = T{},
        -- 2.10.1: the status icons' sort, pins and type order per job, kept the same way (buff_jobs[<JOB>])
        buff_jobs = T{},
        cfg2101 = false,            -- internal: the 2.10.1 changes to saved settings have run
        alliance_compact = true,    -- alliance members get a one-line card (name + health bar)
        locked    = true,
        grow_up   = true,           -- 2.7.6: the list keeps its bottom edge, so a growing party extends upward (you stay at the top)
        from_bottom = false,        -- you at the bottom, the list held by its bottom edge (grows upward); 2.7.1: off (you at the top)
        top271    = false,          -- internal: the 2.7.1 switch to you-at-the-top has run
        bot220    = false,          -- internal: y is the bottom edge (set when that is converted)
        x = 40, y = 320,
        theme     = 'Midnight',
        gap       = 4,              -- space between cards (the only spacing: elements are placed with their offsets)
        gap_ally  = 4,              -- 2.6.0: space between alliance cards
        gap_pet   = 4,              -- 2.6.0: space before and after a pet card
        ally_dock = true,           -- 2.6.2: false = alliance cards in their own window at ally_win (its top left)
        ally_win  = T{ x = 320, y = 320 },
        cards     = T{                -- card sizes in pixels
            link     = true,           -- one width for party, alliance and pet (pet keeps its indent)
            party    = T{ w = 248, h = 92 },
            alliance = T{ w = 248, h = 28 },
            pet      = T{ w = 234, h = 33 },
            sel      = T{ dw = 0, dh = 0 },   -- extra size of the selected card
        },
        lay193    = false,          -- internal: the 1.9.3 layout migration has run
        cfg260    = false,          -- internal: the 2.6 defaults (window rounding 0) have been applied once
        headers   = true,           -- "Party" / "Alliance 1" titles when more than one group is shown
        click_select     = true,    -- click a card to select (and target) that member
        target_on_select = true,    -- selecting (clicking or cycling) also targets the member
        smooth    = true,           -- bars glide to their new value
        out_alpha = 0.45,           -- opacity of members in another zone
        shadow    = true, outline = false, outline_w = 1, outline_color = T{ 0.00, 0.00, 0.00, 0.95 },
        font = 'Default (Ashita)', bold = false, italic = false,   -- the list's own font (a name from the font list in the Enemy bar tab)
        numfont = '', numbold = false,             -- font for the numbers inside bars ('' = same as the list font)
        select_action = 'auto',     -- 'auto' = selecting a member also does what the game is asking for (confirms a pending spell / ability); 'target' = just target them
        debug = false,
        notes = T{},                -- your own short text per member name (lower case): /pxi list note <name> <text>
        pointer = T{ show = true, size = 16, dx = -2, dy = 0, glide = true, glide_speed = 14 },

        anim = T{ enable = true, speed = 1.15, slide = true },   -- fixed since 2.6    -- cards grow / shrink / slide when the party changes
        -- leader / alliance leader / quartermaster marks. style: crown | star | coin | badge | dot | name | strip | none
        -- place: icon (corner of the job icon) | name (after the name) | card (corner of the card)
        roles = T{
            leader  = T{ style = 'crown', place = 'icon', size = 12, color = T{ 1.00, 0.82, 0.20, 1 }, dx = 0, dy = 0 },
            aleader = T{ style = 'star',  place = 'icon', size = 11, color = T{ 1.00, 0.55, 0.20, 1 }, dx = 0, dy = 0 },
            qm      = T{ style = 'coin',  place = 'icon', size = 11, color = T{ 0.50, 0.85, 1.00, 1 }, dx = 0, dy = 0 },
            leader_mask = 1, aleader_mask = 2, qm_mask = 16,      -- which bits of the game's member flags mean what (/pxi list flags prints them)
        },
        -- pets and summons. mode: attached (a small card under the owner) | section (their own "Pets" group, owner named)
        pets = T{ show = true, mode = 'attached', scope = 'party', scale = 0.85, indent = 14, bar_h = 8, mptp = true, show_owner = false, connector = true, glyph = true,
                 dock = true, win = T{ x = 320, y = 520 } },   -- 2.6.2: dock = false: pets in their own window at win (its top left)
        -- party invite: a banner that morphs into a "!" badge. mode: banner | icon | off
        invite = T{ mode = 'banner', banner = 5, timeout = 120, text_scale = 0.85, size = 22, dx = 0, dy = 0, color = T{ 0.99, 0.74, 0.12, 1 }, text_color = T{ 1, 1, 1, 1 }, pulse = true },

        win  = T{ bg = T{ 0.05, 0.06, 0.09, 0.90 }, border = T{ 0.22, 0.27, 0.40, 1 }, border_w = 1, rounding = 0,
                 grad = false, bg2 = T{ 0.03, 0.04, 0.07, 0.90 }, style = 'line', lines = 0,
                 border_file = '', border_slice = 12, top_dy = 0, curved = true },   -- custom border PNG (9-cut); top_dy: where the border starts, from the first group title's middle   -- grad: top color bg > bottom color bg2; style: line | double | glow | bevel | corners | gilded; lines: faint scanlines 0-0.3
        bg   = T{ mode = 'color', file = '', slice = 12, tint = T{ 1, 1, 1, 1 }, scope = 'window', rx_theme = false,   -- rx_theme: RecastXI's theme frame (2.13.1)   -- mode: color | png (one picture) | frame (layered pieces); scope: window | row
               frame = T{ bg = '', fit = 'stretch', tile = 1, top = '', bottom = '', left = '', right = '', tl = '', tr = '', bl = '', br = '', scale = 1, inset = 0 } },
        card = T{ show = true, bg = T{ 0.10, 0.12, 0.18, 0.88 }, border = T{ 0.17, 0.21, 0.31, 1 }, border_w = 1, rounding = 5, hover = true },
        sel  = T{ target = T{ 1, 1, 1, 1 }, cursor = T{ 0.99, 0.82, 0.09, 1 }, select = T{ 0.38, 0.78, 1.00, 1 }, border_w = 2, tint = 0.12, flash = true, sheen = true, repeat_flash = true, repeat_every = 3,
                 fill = T{ 0.38, 0.78, 1.00, 0.12 }, fill261 = false, height = 0,   -- 2.6.1: the selected box's fill color; height: px added to the highlight (0 = card height)
                 lift = true, move_dx = 6, move_dy = 0, rounding = 5 },   -- the selected / targeted member's card moves a little
        head = T{ color = T{ 0.46, 0.58, 0.82, 1 }, scale = 0.80, font = '', bold = false, italic = false, show_solo = false, align = 'left', dx = 0, dy = 0 },
        ptext = T{ z = 4, mode = 'off', brackets = true, scale = 0.80, note_color = T{ 0.74, 0.80, 0.95, 0.85 }, chat_color = T{ 1.00, 0.92, 0.55, 1 },
                   hold = 8, fade = 2, scope = 'all', font = '', bold = false, italic = false, dx = 0, dy = 0 },   -- text next to the name: your note and/or what they just said
        name = T{ z = 2, show = true, color = T{ 0.96, 0.97, 1.00, 1 }, scale = 1.0, caps = false, font = '', bold = false, italic = false, dx = 0, dy = 0 },
        job  = T{ z = 3, show = true, format = 'both', color = T{ 0.58, 0.67, 0.86, 1 }, scale = 0.80, font = '', bold = false, italic = false, dx = 0, dy = 0 },   -- format: both | jobs | main | lv | none
        icon = T{ z = 1, show = true, size = 18, rounding = 4, dx = 0, dy = 0 },     -- job icon: icons\jobs\WAR.png, else a colored tile

        hp = T{
            dx = 0, dy = 0, z = 5, length = 150, auto_len = true,
            text_dx = 0, text_dy = 0, font = '', bold = false, italic = false,   -- the number inside the bar
            sheen = true, comet = 'once', comet_color = T{ 1.00, 1.00, 1.00, 1 }, comet_speed = 1.0,   -- sheen sweep at 100%; comet: off | once (one pass when HP / MP reach 100%, or TP reaches 1000)
            show = true, height = 14, rounding = 4,
            fill = T{ 0.26, 0.78, 0.44, 1 }, warn = T{ 0.96, 0.80, 0.24, 1 }, low = T{ 0.92, 0.26, 0.26, 1 }, by_hp = true,
            warn_at = 0.50, low_at = 0.25, blend = true,   -- health shares: below warn_at the bar turns the warning color, below low_at the low color
            back = T{ 0, 0, 0, 0.55 }, border_on = true, border = T{ 0, 0, 0, 0.90 }, border_w = 1, outline_w = 0, outline = T{ 1, 1, 1, 0.35 },
            gloss = 'glossy', gloss_strength = 0.50,
            text = 'current', text_pos = 'center', text_scale = 0.80, text_color = T{ 1, 1, 1, 1 },
            trail = true, trail_color = T{ 1.00, 0.85, 0.30, 0.90 },
        },
        mp = T{
            dx = 0, dy = 0, z = 6, length = 150, auto_len = true,
            text_dx = 0, text_dy = 0, font = '', bold = false, italic = false,   -- the number inside the bar
            sheen = true, comet = 'once', comet_color = T{ 0.85, 0.93, 1.00, 1 }, comet_speed = 1.0,   -- sheen sweep at 100%; comet: off | once (one pass when HP / MP reach 100%, or TP reaches 1000)
            show = true, height = 9, rounding = 4,
            fill = T{ 0.30, 0.54, 0.96, 1 },
            back = T{ 0, 0, 0, 0.55 }, border_on = true, border = T{ 0, 0, 0, 0.90 }, border_w = 1, outline_w = 0, outline = T{ 1, 1, 1, 0.35 },
            gloss = 'glossy', gloss_strength = 0.50,
            text = 'current', text_pos = 'center', text_scale = 0.70, text_color = T{ 1, 1, 1, 1 },
        },
        tp = T{
            dx = 0, dy = 0, z = 7, length = 150, auto_len = true, glow = true,
            text_dx = 0, text_dy = 0, font = '', bold = false, italic = false,   -- the number inside the bar
            sheen = true, comet = 'once', comet_color = T{ 1.00, 0.92, 0.55, 1 }, comet_speed = 1.0,   -- sheen sweep at 100%; comet: off | once (one pass when HP / MP reach 100%, or TP reaches 1000)
            show = true, height = 9, rounding = 4,
            fill = T{ 0.58, 0.46, 0.94, 1 }, full = T{ 1.00, 0.78, 0.25, 1 }, pulse = true, ticks = true,
            rollover = true, full3 = T{ 1.00, 0.42, 0.25, 1 },    -- rollover: fills once per 1000 TP; fill / full / full3 = 0-999 / 1000-1999 / 2000-3000
            back = T{ 0, 0, 0, 0.55 }, border_on = true, border = T{ 0, 0, 0, 0.90 }, border_w = 1, outline_w = 0, outline = T{ 1, 1, 1, 0.35 },
            gloss = 'glossy', gloss_strength = 0.50,
            text = 'current', text_pos = 'center', text_scale = 0.70, text_color = T{ 1, 1, 1, 1 },
            num_color2 = T{ 1.00, 0.85, 0.30, 1.00 }, num_flash = true, num_flash_speed = 1.5, num_flash_min = 0.35,   -- the number from 1000 TP: its color and a flash
        },

        action  = T{ z = 8, show = true, scale = 0.80, color = T{ 0.78, 0.86, 1.00, 1 }, done_color = T{ 0.62, 0.70, 0.84, 1 },
                     fail_color = T{ 1.00, 0.45, 0.40, 1 }, bar = true, bar_color = T{ 0.99, 0.82, 0.09, 1 }, bar_h = 3, hold = 1.5,
                     font = '', bold = false, italic = false, dx = 0, dy = 0 },
        -- 2.7.0: alliance cards can have their own font sizes, icon / bar sizes and offsets (copied from the party's when
        -- first turned on)
        ally_look = T{ on = false, copied = false,
            name = T{ scale = 1.0, dx = 0, dy = 0 }, job = T{ scale = 0.80, dx = 0, dy = 0 }, icon = T{ size = 18, dx = 0, dy = 0 },
            action = T{ scale = 0.80, dx = 0, dy = 0 },
            hp = T{ height = 14, length = 150, dx = 0, dy = 0, text_scale = 0.80, text_dx = 0, text_dy = 0 },
            mp = T{ height = 9, length = 150, dx = 0, dy = 0, text_scale = 0.70, text_dx = 0, text_dy = 0 },
            tp = T{ height = 9, length = 150, dx = 0, dy = 0, text_scale = 0.70, text_dx = 0, text_dy = 0 } },
        hpnum   = T{ z = 10 }, mpnum = T{ z = 11 }, tpnum = T{ z = 12 },     -- the bar numbers' own layers (font / size / position: in each bar)
        buffs   = T{ z = 9, show = true, size = 16, per_row = 12, max = 24, gap = 1, dx = 0, dy = 0,
                    timers = true, timer_unknown = 'elapsed', timer_pos = 'inside', timer_scale = 0.6, timer_color = T{ 1, 1, 1, 1 },   -- countdown on each icon (only for effects from spells the addon saw land)
                    sort = 'game', pins = T{},     -- sort: game | recent | soonest | longest | type; pins: pinned status ids (in order)
                    pin_mode = T{},                -- 2.10.1: pin_mode['s<id>'] = 'hide' | 'party' (absent = 'top')
                    type_hide = T{},               -- 2.10.2: type_hide[<group>] = true: that type is not shown (By type only)
                    type_order = T{ 'enh', 'heal', 'song', 'geo', 'nin', 'blue', 'divine', 'enf', 'dark', 'elem', 'smn', 'other' },   -- 2.10.1: "By type" group order
                    slide = true,                  -- icons glide to their new place when one ends, is replaced or re-sorted
                    fit = false,                   -- fit to the card: home spot, wrap at the card's width, the card grows per extra row (0.5 s)
                    tooltip = true,                -- name, type, time left when the mouse is on an icon
                    cancel = 'confirm',            -- your own effects: 'confirm' (click, then Yes) | 'click' | 'off'
                    pad = T{ open = '', prev = '', next = '', back = '' },   -- 2.9.1: Open also cancels (no 'ok')   -- learned controller buttons for the cursor ('' = none; pxiinput.lua)
                    flash = true, flash_min = 300, flash_max = 600, flash_strength = 0.8,   -- random flash on beneficial effects
                    fit_pad = 3,                   -- fit to the card: space between the lowest element of the card and the icons
                    ring = 'none', ring_shape = 'circle', ring_width = 2, ring_pad = 2, ring_color = T{ 0.55, 0.95, 0.60, 1.00 },   -- countdown graphic, as on the enemy bar
                    warn_secs = 5, warn_color = T{ 1.00, 0.35, 0.30, 1.00 },   -- the last seconds: number and ring in this color
                    warn_flash = true, warn_speed = 2.5, warn_min = 0.6 },     -- and the icon fades in and out (dimmest opacity warn_min)
    },
}

-- 2.13.3: the shipped defaults: the author's settings over the ones above (pxibase.lua, made by the testkit's gen_base.lua).
-- A first load and Reset everything start from these.
do
    local ok, base = pcall(require, 'pxibase')
    if rawget(_G, 'HPP_NO_BASE') then ok = false end      -- the testkit's tests of the built-in defaults
    if ok and type(base) == 'table' and base.apply then base.apply(D, base.main, T) end
end
return D
