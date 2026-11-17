# Board and fabrication

Open [FDS1010_Budget_E.kicad_pro](CAD/FDS1010_Budget_E.kicad_pro) in KiCad 10. The project contains the original [schematic](CAD/FDS1010_Budget_E.kicad_sch), [PCB](CAD/FDS1010_Budget_E.kicad_pcb), local symbols, 27 footprints and their illustrative VRML component envelopes. The schematic is also available as a [PDF](Docs/Schematic.pdf). Keep the native E.1 and checked manufacturing archive together. The supplier upload and order details remain unverified.

- [E.1 JLCPCB Gerber and drill ZIP](Manufacturing/FDS1010-Rev-E1-Budget-JLCPCB.zip) is the checked two layer 85 × 60 mm release. The board is frozen as ordered. The older E archive is historical.
- [DigiKey order CSV](Manufacturing/Complete%20DigiKey%20Order.csv) and [tab separated upload](Manufacturing/UPLOAD%20TO%20DIGIKEY.txt) hold the same 22 SKUs and 65 items. This basket covers two boards and one shared electrical fixture. Prices in the file are historical.
- [Assembly and Use](Assembly%20and%20Use.pdf) has the placement sequence and orientation. See also the [component guide](Docs/Devboard%20E.1%20Component%20Guide.pdf). PCB bodies belong on top with 71 solder joints underneath. Check the IC notch and diode cathode bands.

| Connector | Pin order | Use |
| --- | --- | --- |
| J1 | 1 VMID, 2 SUM | Detector anode and cathode, or the electrical fixture. Neither detector lead connects to GND. |
| J2 | 1 GND, 2 3V3, 3 ADC | Normal three wire host harness. Use only regulated 3.3 V at J2.2. |
| J3 | 1 GND, 2 3V3, 3 VMID, 4 CSA, 5 GAIN, 6 SHP | Probe in signal order using J3.1 for meter or scope ground. Expect about 3.3 V and 1.65 V at J3.2 and J3.3. With stable dark electronics, the three outputs normally sit near VMID. |
| J4 | Open LOW, shunted HIGH | Gain selection. Remove power to change it. |

**Pico W** uses physical pin 33 AGND, 36 3V3 OUT and 31 GP26/ADC0. **UNO R4 Minima** uses GND and A0 with an external regulated 3.3 V supply sharing that ground. Keep the Uno 5 V and VIN away from the Devboard. Optional diagnostic inputs are Pico GP27/ADC1 and GP28/ADC2 or Uno A1 and A2. Declare the actual probe wiring, keep the J2 harness, and choose one channel at a time for acquisition. The pin diagrams show the physical connections. [Pico and Uno wiring](Pico%20W%20and%20UNO%20R4%20Minima%20to%20Rev%20E.1%20Wiring.png)

The MCP6024 implements a 100 MΩ / 10 pF charge amplifier, a driven midpoint, 27.15 or 53.3 postgain, and a nominal 499 µs shaper. The 1 kΩ / 1 nF ADC network has BAT85 clamps. E.1 keeps the E netlist and parts and shortens the C2 bypass path near U1.4. Control board leakage, wiring pickup, and clipping before relying on the signal. KiCad release checks documented one ERC and two DRC warnings for the intentional GUARD electrode, with zero errors. [Verification](Docs/Verification/) · [Analog analysis](Docs/Analysis/Analog%20Analysis.md)
