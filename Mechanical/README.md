# Mechanical and assembly geometry

[Rev E.1 Bare Board.step](Rev%20E.1%20Bare%20Board.step) is the bare PCB solid exported directly from the frozen KiCad PCB for mounting and enclosure clearance. It follows the native board origin. Measure enclosure fit against the native CAD and actual assembled parts. The supplied model is an 85 × 60 mm board with four 3.5 mm mounting holes. Keep the J2 harness, detector leads, and J4 service access clear.

- [Native PCB](../CAD/FDS1010_Budget_E.kicad_pcb) defines outline, footprint placement and drilled features. [CAD/Models](../CAD/Models/) holds the local VRML envelope models referenced by the board. Preserve their relative paths.
- [Bare top](Renders/01%20Rev%20E%20Bare%20Top.png), [bare bottom](Renders/02%20Rev%20E%20Bare%20Bottom.png) and [populated isometric](Renders/Populated%20Rev%20E.1.png) show orientation. Illustrative body shape, finish and band colors do not identify received parts.
- [Render Source](Render%20Source/) reconstructs the 27 placements from the native board and component geometry. The Python script reads the native pad shapes, coordinates and drills. Blender uses these inputs for the assembly sequence and part views.

From the repository root, `sh Tools/export-board-step.sh` regenerates the bare STEP using KiCad CLI. `sh Tools/render-board.sh` generates the main assembly render with Blender and Python with Pillow. For all 27 stages, details and geometry verification, run `sh Tools/render-board.sh .build/renders --all`. Set `KICAD_CLI` or `BLENDER` if tools are installed elsewhere. Builds and generated intermediates go under `.build/` by default. See the [assembly PDF](../Assembly%20and%20Use.pdf) for the assembly sequence and wiring.
