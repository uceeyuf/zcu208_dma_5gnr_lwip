# Host MATLAB library (`host/matlab`)

| File | Purpose |
|---|---|
| `RfsocEth.m` | TCP client for the board server (`vitis/src/net_server.c`): `ping`, `write(addr, bytes)`, `read(addr, n)`, `exec(cmd)`, `cmd(cmd)` |
| `play_capture_eth.m` | one call = upload a waveform, start the DAC player, capture the ADC, read the capture back |
| `demo_5gnr_loopback.m` | 100-MHz NR 64QAM frame, play + capture, alignment, PDSCH EVM, spectrum and constellation figure |
| `demo_image_payload.m` | an image as the DL-SCH payload of one 64QAM frame, play + capture, decode, image and constellation figure |
| `img_make_waveform.m` | image -> 16-byte header + row-major pixels -> PDSCH DataSource -> 200 MS/s waveform and metadata |
| `img_align.m` | frame alignment by non-coherent block-wise correlation (tolerates the residual DAC/ADC frequency offset) |
| `img_rx_decode.m` | PDSCH receiver: timing, data-aided CFO, OFDM demodulation, DM-RS channel estimate, MMSE, LDPC decoding, image |

## Wire protocol

Little-endian `uint32` header `magic | cmd | addr | len`, magic `0x52464E54` ('RFNT'), port 7000, one request at a time.

| cmd | Meaning | Payload | Reply |
|---|---|---|---|
| 1 WRITE | copy `len` bytes to `addr` | `len` bytes | `magic | status` |
| 2 READ | read `len` bytes from `addr` | – | `magic | status`, then `len` bytes |
| 3 EXEC | run one console command line | `len` bytes of text | `magic | status` (0 = XST_SUCCESS) |
| 4 PING | liveness | – | `magic | 0` |

Addresses below `0x80000000` are DDR (the server keeps the data cache coherent); addresses at or above are AXI
targets in the PL, written with 32-bit accesses, at most 64 KB per request.

## Memory map used by the host

| Address | Content |
|---|---|
| `0x40001000` | DAC play buffer, int16 `I0 Q0 I1 Q1 ...`, 200 MS/s |
| `0x10001000` | ADC capture buffer, int16 `I0 Q0 I1 Q1 ...`, 200 MS/s |

## Console commands (EXEC)

`dacPlay <KB>` (start cyclic playback of the first `<KB>` kilobytes of the play buffer), `dacStop`,
`adcCapture <KB>`, `rfdcReady`, `dacCurrent`, `adcDecimation`, `dacInterpolation`, `memread <addr>`,
`memwrite <addr> <value>`, `rfread` / `rfwrite <offset>`. The same commands are available on the UART console
(115200 8N1); `?` lists them.

## Example

```matlab
E = RfsocEth();              % 192.168.1.10:7000
E.ping()
E.cmd('rfdcReady');
delete(E);

z = 0.5*exp(1j*2*pi*10e6/200e6*(0:2^20-1)).';   % 10-MHz tone, one 4-MB cycle
[rx, info] = play_capture_eth(z);
```
