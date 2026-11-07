# Gizmo Vlog Builder (DaVinci Resolve script)

Builds a ~90 s, 2.39:1 cinematic, beat-cut edit called "Day in the Life of Gizmo the Gremlin"
from the clips and song already in your Resolve project. It creates a **new** project and does not change your original one.

## Install (one time)

1. Download `Gizmo Vlog Builder.lua`.
2. Copy it into Resolve's scripts folder. Create the `Utility` folder if it doesn't exist.
   - **Mac:** `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/`
     (in Finder: Go → Go to Folder…, then paste the path)
   - **Windows:** `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\`
3. Restart Resolve.

## Run (paste into the Console, which is the method that worked on Resolve 21 free)

1. Open the project that has your DJI clips and the song.
2. Open **Workspace → Console**, make sure it is on **Lua**, and click **Cls** to clear it.
3. Open `Gizmo - paste into Console (short lines).txt`, copy everything in it, paste it into the empty Console input, and press Enter.
4. Wait up to a minute. A new project called "Gizmo - Day in the Life" opens with the edit.

On Resolve 21 free, **Workspace → Scripts** lists the script but it doesn't visibly run, and Lua scripts aren't allowed to read files there. Because of that, automatic brightness measurement is skipped and every clip gets the cinematic look only.

If you change `Gizmo Vlog Builder.lua`, rebuild the paste file from it. It's the same code with comments removed, split into short `GZ=GZ..[==[...]==]` lines, with `assert(loadstring(GZ))()` as the last line.

## After it runs (about 1 minute of manual polish)

- **Transitions:** in the Edit page, select all clips on V1 (click the first clip, then Shift-click the last) and press **Cmd+T** (Mac) or **Ctrl+T** (Windows) to add cross dissolves. Or keep the hard cuts, which hit harder on the beat.
- **Music fade-out:** drag the small white handle at the top-right corner of the song clip to the left.
- **Check the grade:** scrub through the Color page. Each clip's correction is on node 1, and you can tweak any clip there.

## Tweaks (edit the `CONFIG` block at the top of the script, then run it again)

| Setting | What it does |
|---|---|
| `FIRST_BEAT` | If the cuts feel slightly early or late, set this to the time (in seconds) of the first drum hit in the song |
| `BPM` | Tempo of the beat grid (default 109) |
| `TARGET_SECONDS` | Video length |
| `LOOK_SATURATION`, `LOOK_SLOPE`, `LOOK_OFFSET` | Strength of the cinematic look |
| `TITLE_FONT`, `TITLE_STYLE` | Title font |

**Perfect beat sync:** in your original project, double-click the song to open it in the Source viewer, play it, and tap **M** on each beat where you want a cut (at least 8 markers). Then run the script again. It will cut on your markers instead of the BPM grid.

Each run creates a new project ("Gizmo - Day in the Life 2", "… 3", …), so you can compare versions.
