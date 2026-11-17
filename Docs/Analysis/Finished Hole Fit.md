# Rev E finished-hole fit check

Independent package-fit check for the proposed PCB finished hole diameters: 1.00 mm passive/DIP holes, 1.10 mm Harwin header holes, and 2.00 mm copper pads. This is dimensional evidence only; it does not inspect the Rev E KiCad footprints, drill files, plating process, assembly samples, or JLCPCB CAM interpretation.

## Method

Use the stated JLC finished-hole lower tolerance of −0.08 mm: 1.00 mm nominal gives a 0.92 mm minimum finished bore; 1.10 mm nominal gives a 1.02 mm minimum. For round leads, radial clearance is `(minimum bore − maximum lead diameter)/2`. For a square/rectangular lead, compare the bore to the maximum corner-to-corner diagonal. Copper ring below is `(2.00 − maximum finished hole)/2`, using +0.08 mm upper finished-hole tolerance. It assumes that 1.00/1.10 are finished sizes rather than tool/drill sizes.

| Part family / exact planned part | Manufacturer drawing maximum | Hole minimum | Minimum radial fit margin | Result |
|---|---:|---:|---:|---|
| Yageo MFR-25, all MFR-25FRF52 / MFR-25FBF52 resistors | Lead Ø 0.55 ± 0.05 = **0.60 mm max** | 0.92 mm | **0.160 mm** | Fits dimensionally |
| Stackpole RNF14FTD, 1 kΩ and 100 Ω axial resistors | Lead Ø 0.56 ± 0.08 = **0.64 mm max** | 0.92 mm | **0.140 mm** | Fits dimensionally |
| KEMET C317C100J1G5TA, 10 pF C0G | C317 lead Ø 0.020 in +0.004/−0.001 = **0.61 mm max**; pitch 5.08 mm | 0.92 mm | **0.155 mm** | Fits dimensionally |
| TDK FG18/FG28/FG24 and FA18 radial MLCCs, including C2/C1,C3/C6/C5,C7/C8 | Manufacturer spec: lead Ø 0.50 +0.10/−0.03 = **0.60 mm max**; FG18/FA18 pitch 2.5 mm, FG28/FG24 pitch 5.0 mm | 0.92 mm | **0.160 mm** | Fits dimensionally |
| Vishay BAT85S-TA DO-35 diodes | Lead Ø **0.60 mm max** | 0.92 mm | **0.160 mm** | Fits dimensionally |
| Microchip MCP6024-E/P 14-PDIP | Rectangular lower lead max width 0.022 in (0.559 mm), thickness 0.015 in (0.381 mm); diagonal **0.677 mm** | 0.92 mm | **0.122 mm** corner radial margin | Fits dimensionally |
| Harwin M20-9990245/0345/0645 header tails | Square pin 0.64 ±0.02 = **0.66 mm max**; diagonal **0.933 mm** | 1.02 mm | **0.043 mm** corner radial margin | Fits, small but positive margin |
| Murata MHR0317SA107F70 100 MΩ resistor | Manufacturer drawing: body 17.6 × 2.5 mm max, 15.24 ±0.3 mm lead pitch; lead detail marks **0.2 mm max** and **(0.5 mm) reference**. The reference width has no tolerance/max. | 0.92 mm | Nominal 0.20 × 0.50 mm diagonal ≈0.54 mm would leave ~0.19 mm radial, **but no guaranteed maximum diagonal is stated** | **Not certified from drawing; verify actual received lead or obtain manufacturer clarification before final hole freeze** |

## Pad annular ring

With 2.00 mm copper pads, maximum holes of 1.08 mm passive and DIP, and 1.18 mm header, the nominal worst-case radial copper rings are respectively **0.46 mm** and **0.41 mm**. Both exceed the plan’s 0.30 mm minimum annular-ring target by 0.16 mm and 0.11 mm. The MHR lead uncertainty does not change this copper-ring arithmetic; it affects component insertion fit.

Harwin’s own M20 drawing recommends a Ø1.02 ±0.05 mm PCB mounting hole. The planned 1.10 mm finished hole, under the −0.08 mm finished-size assumption, bottoms at 1.02 mm. That matches the drawing’s recommended nominal minimum; the computed pin-to-hole corner clearance is only about 0.043 mm radial at the minimum hole, so verify the fabricator’s finished-size semantics and an actual sample before assuming effortless hand insertion. The specified 2 mm pad leaves 0.41 mm radial copper at the maximum bore.

## Part-specific source notes

* **Yageo MFR-25:** Manufacturer YAGEO MFR data sheet identifies lead diameter ψd = 0.55 ±0.05 mm. Official PDF: https://yageogroup.com/content/Resource%20Library/Datasheet/YAGEO-MFR_DATASHEET.pdf. The exact chosen MFR-25 52 forming code does not increase the conductor diameter.
* **Stackpole RNF14:** Manufacturer SEI RNF/RNMF series drawing lists RNF14 lead diameter 0.56 ±0.08 mm. Official PDF: https://www.seielect.com/catalog/sei-rnf_rnmf.pdf.
* **KEMET C317:** C1049 Goldmax C0G drawing gives Style 317 lead pitch 0.200 in (5.08 mm), diameter 0.020 in +0.004/−0.001 in (maximum 0.61 mm). Official PDF: https://content.kemet.com/datasheets/KEM_C1049_GOLDMAX_C0G.pdf.
* **TDK FG and FA dipped MLCCs:** TDK dimension specification gives FG18/FG28/FG24 and FA18 wire diameter 0.5 +0.10/−0.03 mm, with 2.5 or 5.0 mm pitch by series. Official PDFs: https://product.tdk.com/system/files/dam/doc/product/capacitor/ceramic/lead-mlcc/specification/leadmlccspec_halogenfree_fg_en.pdf and https://product.tdk.com/system/files/dam/doc/product/capacitor/ceramic/lead-mlcc/specification/leadmlccspec_halogenfree_fa_en.pdf.
* **Vishay BAT85S-TA:** DO-35 maximum lead diameter 0.60 mm. Official PDF: https://www.vishay.com/docs/85513/bat85s.pdf.
* **Microchip MCP6024-E/P:** DS20001685E package drawing identifies 14-lead PDIP, 0.100 in pitch and lead width/thickness maxima; use max width × thickness to test diagonal, not one dimension alone. Official PDF: https://ww1.microchip.com/downloads/en/DeviceDoc/20001685E.pdf.
* **Harwin M20-999:** drawing M20-999 specifies 0.64 ±0.02 mm square and recommended PCB hole Ø1.02 ±0.05 mm. Official part page with drawing link: https://www.harwin.com/products/M20-9990245. Archived drawing search result: https://www.digikey.in/htmldatasheets/production/1191331/0/0/1/m20-9992045.pdf.
* **Murata MHR0317SA:** official series sheet confirms 15.24 ±0.3 mm pitch and body dimensions; lead detail is not a full tolerance envelope for the transverse conductor dimension. Official PDF: https://www.murata.com/-/media/webrenewal/products/resistor/highvoltage/mhr0317sa_series_data_sheet.ashx?la=en.

## Release checkpoint

The proposed 1.00 mm finished holes have positive dimensional fit margin for every sourced passive except the Murata 100 MΩ lead, whose drawing does not provide a tolerance/max for the reference 0.5 mm transverse dimension. The 1.10 mm Harwin header hole clears the maximum pin diagonal, but with modest margin. Do not mark all placements “verified fit” until MHR wire size is measured on the received part or its guaranteed maximum is confirmed, and until JLC CAM confirms that the submitted drill values produce the assumed finished-hole tolerances. Verify the final Kicad pad sizes, finished-hole attributes, and annular rings from generated board/drill data; this report does not assert that CAD check has occurred.
