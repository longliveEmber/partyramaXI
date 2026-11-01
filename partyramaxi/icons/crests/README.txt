Custom header crests
====================
Set "Header crest" to "Custom PNG" in /pxi config -> RecastXI -> Appearance -> Header.

  crests\<job>.png   per-job crest, e.g. crests\drg.png, crests\rdm.png (used first when
                     "Per-job file" is on)
  the "File" setting  any PNG (relative to the icons folder, or a full path)
  crests\default.png  fallback (ships with RecastXI: an original rendering of the Holy Crest)

If no file is found, the theme's own drawn crest is used. Square PNGs with transparency look
best; the mask (circle / square / none) and size are on the same tab.
