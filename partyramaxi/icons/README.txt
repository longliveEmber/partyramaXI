PartyramaXI icons
===================

Every picture PartyramaXI uses lives in this folder. After adding files, press Rescan in /pxi config
(or reload the addon: /addon reload partyramaxi).

  packs\<Pack>\     Icon packs, one folder each (for example HXUI's status icons 0.png .. 639.png).
                    Used by the target bar's effect icons, the party list's status effects and RecastXI.
                    Pick one pack and one fallback pack in /pxi config > Target bar > Icons.
                    A pack may hold base.txt: its first line names another pack, and pictures missing
                    from this pack come from that one (Colorul_HD Ult builds on colorful-combined).
                    RecastXI picks its own pack and fallback pack on its Icons tab. For spell and ability
                    icons a pack may hold spells\<id 5 digits>.png and abilities\<id 5 digits>.png
                    (XIUI hotbar names, e.g. spells\00109.png = Refresh); HXUI status packs are matched
                    by the status a spell or ability gives.
  status\           Loose status effect icons, named by status id: 134.png (Dia), 2.png (Sleep)...
                    00134.png / 00000134.png style names work too. Used after the chosen packs.
  jobs\             Job icons for the party list: WAR.png, WHM.png ... (a colored tile is drawn without one).
  arrows\           Pointer pictures (PNG, pointing down, transparent background).
  elements\         Element icons (Fire.png, Ice.png ...): RecastXI and the target bar's weakness icons. Glossy; the flat set is in elements\flat\, the painted set in elements\painted\, the jewel set in elements\jewel\.
  weak\             Target bar weakness icons for damage types: Slashing, Piercing, Blunt, H2H, Magic (.png). Glossy set; the flat set is in weak\flat\, the jewel set in weak\jewel\.
  mob\              Target bar monster info badges: NM, Aggro, Link, TrueSight, Sight, Sound, Scent, Magic, LowHP, Ability, Charm (.png). Glossy set; the flat set is in mob\flat\, the jewel set in mob\jewel\.
  categories\       RecastXI: magic type icons (healing.png, enfeebling.png ...), glossy; the flat originals are in categories\flat\, the jewel set in categories\jewel\.
  badges\           Target bar > Players: the name icons left of a player's name: lfp, sync, anon, away, bazaar, mentor, new, dc, gm (.png).
  crests\           RecastXI: header crests (default.png, or <job>.png).
  fx\               RecastXI: header pattern tiles for its themes.
  generic.png       RecastXI: the last fallback icon.

Anything without a picture gets a drawn tile with letters, so nothing breaks when a file is missing.
Game icons belong to Square Enix and the pack authors: keep them in your own install.
