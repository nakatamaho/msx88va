# Roadmap

| Milestone | Content | State |
|---|---|---|
| M01 | Compatible-mode I/O trap: function and cost, probe disk | passed on VA2 (2026-10-16); VA pending |
| M02 | C-BIOS boot, slots, VDP graphics I/II and text, PSG, test cartridge, VRAM block calls by CALLN | runs on VA and VA2 (2026-10-18); PSG untested |
| M03 | BIOS I/O by CALLN, keyboard and joystick, changed-cell rendering, TSP sprites with software flags, PSG, HELP as MSX reset | passed on VA and VA2 (2026-10-18) |
| M04 | Real cartridges (two 1984 titles play in vaeg), C-BIOS exit registers, MS-DOS 4.0 disks only | in progress; hardware pending |
| M05 | Graphics I on the TSP text screen with gaiji characters: PCGTEST probe, then in MSX.COM (GAIJI.BAK, /R, /N) | probe passed on VA and VA2 (2026-10-21); MSX program in vaeg (2026-10-22), hardware pending |

Next: speed (docs/HANDOVER-speed.md), OUT-loop patterns, a trap profiler,
then per-title patches for VRAM loops and mappers.
