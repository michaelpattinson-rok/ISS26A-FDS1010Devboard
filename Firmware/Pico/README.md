# Signal Bench Pico W 1.10

Build `signal_bench_stream` for `pico_w` with the installed Pico SDK. The separate finite `signal_bench` and legacy `fds1010_reve` targets remain available. Use the released image for the original RP2040 Pico W. Fixture output is disabled. [Build, tests and images](../README.md)

## Stream negotiation

The safe `?` identity probe and protocol version 1 remain in use. Firmware 1.10 advertises `avg_stream=1` and `stream_timing=1`. The raw ADC presets and 10,000 to 500,000 custom interval use the same divider logic as 1.9. The app checks the requested channel, clock and divider at Start. One ADC input is active at a time. [Pico SDK ADC API](https://www.raspberrypi.com/documentation/pico-sdk/hardware.html#hardware_adc)

For 1×, retain the existing start command and frame layout. Continue to use ` PACK12` above 250,000 raw conversions/s. A client that sees `stream_timing=1` can append ` METRICS` after any packing token to request the extended End payload.

For an averaged run, append ` AVG1 N` instead of ` PACK12`, where `N` is 4, 8, 16, 32 or 64. Start includes the existing ADC clock and divider followed by an unsigned 32 bit factor. Sample frames use flag 4 and contain exactly `2048/N` complete groups. The header's first index is the original raw conversion index and the count is the number of groups. The timer anchor marks completion of the DMA block. GPIO and End indices are original raw conversion boundaries on the wire.

Each AVG1 group is a little endian field. For `k = log2(N)`, the low `12+k` bits contain the exact integer sum of the non-error ADC codes. Three fields of `1+k` bits follow in order for ADC errors, low rail hits and high rail hits. Spare high bits are zero. Group sizes are 3, 4, 4, 5 and 5 bytes. The group represents original conversions from `index*N` through `(index+1)*N-1` when indexed in the Project. Rail or error groups have no usable mean. The foreground builds group frames. DMA and the GPIO output lease keep their original roles.

With `METRICS` or `AVG1`, End contains 32 bytes. In order these are a 64 bit count of readings sent, 32 bit Pico queue peak, 32 bit maximum preparation time in microseconds, 64 bit longest USB no-progress interval in microseconds, and 64 bit total time spent in those intervals. The timing is measured in firmware around preparation and CDC writes. It includes time interrupted by DMA work and does not independently measure line bandwidth. The host validates End before considering a recording reconciled.

| Stop code | Meaning |
| --- | --- |
| 0 | Clean stop and drain |
| 1 | Pico streaming buffer filled |
| 2 | ADC FIFO overrun or timing failure |
| 3 | USB link interruption |
| 4 | Pico connection or output lease expired |

A buffer-full stop identifies the known missing complete block. FIFO faults or missing End information leave coverage unconfirmed. The app keeps the verified prefix and resumes only into a separate segment.
