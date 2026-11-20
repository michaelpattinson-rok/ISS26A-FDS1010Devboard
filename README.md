# FDS1010 Devboard E.1

Rev E.1 is an 85 × 60 mm, two layer, through hole Devboard for one FDS1010 channel. Signal Bench 3.7.11 records the board over USB using the original Raspberry Pi Pico W or Arduino UNO R4 Minima.

| Start here | Contents |
| --- | --- |
| [Assembly and use PDF](Assembly%20and%20Use.pdf) | 77 pages covering components, soldering, orientation, wiring, diagnostics, and bench checks. The software pages document the earlier finite capture workflow. |
| [Pico wiring PNG](Pico%20W%20to%20Devboard%20E.1%20Wiring.png) · [Uno wiring PNG](Arduino%20UNO%20R4%20Minima%20to%20Rev%20E.1%20Wiring.png) | Physical pins and power for both supported Signal Bench hosts. |
| [Board and ordering](BOARD.md) | Editable KiCad, fabrication archive, two board DigiKey basket, jumper and probe map, and design checks. |
| [Arduino run data](Data/README.md) | Full Arduino Project archive, run index, and SHA-256 checks. |
| [Firmware](Firmware/README.md) · [macOS app](Software/README.md) | App download, firmware images, operation, and verification. |
| [Mechanical](Mechanical/README.md) | Bare board STEP, assembly geometry, Blender scripts, and three reference views. |

Use one host and a regulated **3.3 V Devboard supply**. Remove power before changing wiring or J4. Connect J1.1 VMID to the FDS1010 anode and J1.2 SUM to its cathode. Keep both detector leads off ground. Start with a known ADC input and Main at 100,000 samples/s, 1×. See the board and firmware guides before power up.
