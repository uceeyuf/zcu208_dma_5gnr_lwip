# lwIP BSP settings

`xsct/build.tcl` adds `lwip211` (lwIP 2.1.1, library version 2.0) to the `standalone_domain` of the platform and sets:

| Parameter | Value | Why |
|---|---|---|
| `api_mode` | `RAW_API` | bare-metal, single-threaded server (`net_server.c`), no RTOS |
| `lwip_dhcp` | `false` | static address 192.168.1.10/24, gateway 192.168.1.1 (`net_server.h`) |
| `dhcp_does_arp_check` | `false` | DHCP not used |
| `tcp_snd_buf` | 65535 | large send window for the capture read-back |
| `tcp_wnd` | 65535 | large receive window for the waveform upload |
| `mem_size` | 524288 | lwIP heap |
| `memp_n_pbuf` | 2048 | pbuf pool entries |
| `memp_n_tcp_seg` | 1024 | queued TCP segments |
| `pbuf_pool_size` | 4096 | receive pbufs |
| `n_tx_descriptors` | 256 | GEM DMA descriptors |
| `n_rx_descriptors` | 256 | GEM DMA descriptors |

Everything else is the lwip211 default. The application links `m`, `metal` (RFdc driver) and `lwip4`.

Ethernet: GEM3 on MIO 64–75 (RGMII, MDIO on MIO 76–77), the ZCU208 on-board RJ45. Enabled in the block design
(`zynq_ultra_ps_e_0`), so no hardware change is needed beyond the original DMA design.

To change the board address edit `RFNET_IP0..3` / `RFNET_GW3` in `vitis/src/net_server.h` and rebuild the application.
