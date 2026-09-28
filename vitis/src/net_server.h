/*
 * net_server.h — 1GbE (PS GEM3, lwIP raw API) control/data server for the RFSoC bench.
 *
 * Replaces the xsct/JTAG data path (waveform download, LUT write/read-back, capture
 * read-back) and optionally the UART command path with one TCP connection.
 *
 * Wire protocol (all little-endian, one request at a time per connection):
 *   request header  : u32 magic (RFNET_MAGIC) | u32 cmd | u32 addr | u32 len
 *   RFNET_CMD_WRITE : header + len payload bytes -> copied to physical address addr
 *                     (DDR: direct; AXI/BRAM >= 0xA0000000: staged, 32-bit word writes)
 *                     reply: u32 magic | u32 status
 *   RFNET_CMD_READ  : header -> reply: u32 magic | u32 status, then len bytes from addr
 *   RFNET_CMD_EXEC  : header + len bytes of CLI text ("dacPlay 8192", "cfrSet 2 3456"...)
 *                     -> runs through the existing CLI parser; reply: magic | status
 *                     (status = XST_SUCCESS / XST_FAILURE(command not found, arg count) )
 *   RFNET_CMD_PING  : header -> reply: magic | status(0)
 *
 * Host side: rfsoc_dma_cfr_lwip/RfsocEth.m (MATLAB tcpclient).
 */
#ifndef NET_SERVER_H
#define NET_SERVER_H

#include "xil_types.h"

#define RFNET_MAGIC      0x52464E54u   /* 'RFNT' */
#define RFNET_PORT       7000
#define RFNET_CMD_WRITE  1u
#define RFNET_CMD_READ   2u
#define RFNET_CMD_EXEC   3u
#define RFNET_CMD_PING   4u

/* Static addressing (no DHCP): board 192.168.1.10/24, host expected at 192.168.1.1 */
#define RFNET_IP0 192
#define RFNET_IP1 168
#define RFNET_IP2 1
#define RFNET_IP3 10
#define RFNET_GW3 1

/* Bring up GIC + GEM + lwIP + listening socket. Returns XST_SUCCESS / XST_FAILURE. */
int  net_init(void);
/* Call from the main loop as often as possible: services RX packets and TCP timers. */
void net_poll(void);

#endif /* NET_SERVER_H */
