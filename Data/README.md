# Arduino UNO R4 Minima recordings

This archive contains the complete `UnoDataCollection` Signal Bench Project with seven Uno R4 Minima runs, including the verified saved prefixes of interrupted runs. It includes the original ADC readings, per-frame timing, Project and run manifests, calibration data, annotations, quality reports and other files present in the Project. The Pico Project is separate. Finder cache files and transient writer locks were omitted.

| Run | Status | Configured samples/s | Saved readings | Known missing readings |
| --- | --- | ---: | ---: | ---: |
| Uno Nothing | Interrupted | 250,000 | 450,001,920 | 1,024 |
| Uno+DevboardPluggedIn | Complete | 250,000 | 203,780,400 | 0 |
| MainFDS1010AndDevboard | Complete | 250,000 | 228,393,264 | 0 |
| 5min Foil Run | Complete | 250,000 | 75,009,328 | 0 |
| Main recording 1795134836 | Interrupted | 250,000 | 0 | 0 |
| Main recording 1795134845 | Complete | 250,000 | 632,112 | 0 |
| With Cesium Source, FDS1010 Run | Interrupted | 250,000 | 110,111,024 | 27,648 |

Known missing readings count reported loss. Time after an early stop can be unrecorded without being included in that count. These recordings describe the saved signals and their coverage.

## Download and verify

Download the `Parts/` folder along with this directory, or download the repository ZIP from GitHub and extract it first. Keep the part names unchanged. In this directory on macOS, run the commands below in a fresh directory. Keep the checksum files and `Parts/` together.

```sh
set -e
test ! -e UnoDataCollection
test ! -e UnoDataCollection.tar.gz
shasum -a 256 -c "Parts SHA256SUMS.txt"
cat Parts/UnoDataCollection.tar.gz.part-* > UnoDataCollection.tar.gz
shasum -a 256 -c "Archive SHA256SUMS.txt"
tar -xzf UnoDataCollection.tar.gz
shasum -a 256 -c SHA256SUMS.txt
```

Choose **Open Project** in Signal Bench and select the extracted `UnoDataCollection` folder.

The 97 parts total **1,013,684,990 bytes**. The original Project contains **12,246 files** totaling **2,238,145,603 bytes**. Every archived file was checked against its source SHA-256 before upload.
