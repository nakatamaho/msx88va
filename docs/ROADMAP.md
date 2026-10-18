# Roadmap

| Milestone | Content | State |
|---|---|---|
| M01 | Compatible-mode I/O trap: function and cost, probe disk | passed on VA2 (2026-10-16); VA pending |
| M02 | C-BIOS boot, slots, VDP graphics I/II and text, PSG, test cartridge, VRAM block calls by CALLN | runs on VA and VA2 (2026-10-18); PSG untested |
| M03 | BIOS I/O by CALLN, keyboard and joystick, changed-cell rendering, TSP sprites with software flags, PSG, HELP as MSX reset | passed on VA and VA2 (2026-10-18) |

Next: a trap profiler (traps by Z80 PC), sprite flags, OUT-loop patterns;
then per-title patches for VRAM loops and mappers.
