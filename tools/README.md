# Sprite tools

For replacing a ped's sprites with generated ones (e.g. the German version's humanoid robot grid girl).
Run from the app folder.

1. `luajit tools/dump_pixfile.lua DATA/PIXELMAP/RID.PIX DATA/REG/PALETTES/DRRENDER.PAL <dir>`: every frame of a
   sprite file as raw RGBA plus `index.txt` (name, size).
2. `python3 tools/template_sheet.py <dir> "<title>" template.png`: a sheet for an image generator. Every frame at
   3x on flat magenta (#FF00FF) in a fixed grid of equal cells, feet 12 px above each cell's bottom. Ask the
   generator to keep the grid and the magenta and repaint only the figures.
3. `python3 tools/sheet_to_pix.py generated.png <dir>/index.txt DATA/REG/PALETTES/DRRENDER.PAL RID.PIX <tmp>`:
   the generated sheet back to a C1 sprite file. Cells are cut by position, the magenta keyed out, each frame
   shrunk to native size (grown where the figure is bigger, feet and centre kept), converted to the game's palette
   (index 0 transparent), and written with the original frame names, so the ped's animations use it unchanged.
4. `luajit tools/splice_ped.lua <into> <from> <GENERAL.TXT> <ref> <out>`: one ped's entry copied from one ped file
   into another (e.g. ped 19 from PEDESTRN.TXT into BORING.TXT, so the German grid girl uses RID.PIX and keeps her
   GET READY sign). Both files must use the same cipher.

Needs Python 3 with Pillow and NumPy, and LuaJIT.
