/*
 * net_server.c — 1GbE control/data server (lwIP 2.1 raw API, NO_SYS=1, PS GEM3).
 *
 * BSP requirement (Vitis platform -> standalone domain -> Board Support Package settings):
 *   library lwip211, api_mode = RAW_API, dhcp = false, and for throughput
 *   tcp_snd_buf 65535, tcp_wnd 65535, pbuf_pool_size 1024, mem_size 524288,
 *   n_tx_descriptors 512, n_rx_descriptors 512, tcp_ip_rx_checksum_offload true,
 *   tcp_tx_checksum_offload true (see README_lwip.md).
 *
 * Design notes
 *   - Polled main loop (no RTOS): net_poll() runs xemacif_input() + TCP fast/slow timers
 *     driven by the A53 global timer (XTime), so no TTC interrupt is needed. The GEM itself
 *     is interrupt driven (GIC), exactly as in the Xilinx lwIP templates.
 *   - Caches: the DAC waveform buffer (DDR) is written by the CPU and read by the TX DMA ->
 *     Xil_DCacheFlushRange after a WRITE; the ADC capture buffer is written by the RX DMA and
 *     read by the CPU -> Xil_DCacheInvalidateRange before a READ. JTAG (DAP) bypassed the
 *     caches, so the old flow never needed this.
 *   - AXI targets (LUT BRAM at 0xA0044000): the AXI BRAM controller is 32-bit; TCP payload
 *     boundaries are arbitrary, so such writes are staged and issued as aligned 32-bit words.
 *   - One request at a time per connection; the host waits for the reply before the next.
 */
#include <string.h>
#include "net_server.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xstatus.h"
#include "xtime_l.h"
#include "xscugic.h"
#include "xil_exception.h"

#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/priv/tcp_priv.h"     /* tcp_fasttmr / tcp_slowtmr (driven from net_poll) */
#include "lwip/ip_addr.h"
#include "netif/xadapter.h"

#include "cli.h"

/* The Xilinx xemacpsif adapter (NO_SYS build) expects this GIC instance to exist. */
XScuGic xInterruptController;

/* ------------------------------------------------------------------------- */
#define STAGE_SIZE      (64u * 1024u)          /* max non-DDR (AXI/BRAM) write size */
#define DDR_LIMIT       0x80000000u            /* below: DDR (cached); above: AXI/PL */
#define HDR_LEN         16u
#define REPLY_LEN       8u

typedef enum { ST_HDR = 0, ST_WRITE_PAYLOAD, ST_EXEC_PAYLOAD, ST_SENDING } conn_state_t;

typedef struct {
    struct tcp_pcb *pcb;
    conn_state_t    st;
    u8              hdr[HDR_LEN];
    u32             hdr_got;
    u32             cmd, addr, len;
    u32             got;               /* payload bytes received so far */
    /* READ streaming */
    const u8       *tx_ptr;
    u32             tx_left;
    u8              reply[REPLY_LEN];
    u8              reply_pending;
    char            exec_line[LINEMAX];
} conn_t;

static struct netif  server_netif;
static struct tcp_pcb *listen_pcb;
static u8      stage_buf[STAGE_SIZE] __attribute__((aligned(64)));
static conn_t  conn;                               /* single active connection */
static XTime   t_fast, t_slow;

/* --------------------------------------------------------------------------
 * helpers
 * ------------------------------------------------------------------------ */
static u32 rd32(const u8 *p) { return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }
static void wr32(u8 *p, u32 v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF; }

static void conn_reset_request(conn_t *c)
{
    c->st = ST_HDR; c->hdr_got = 0; c->got = 0; c->tx_ptr = NULL; c->tx_left = 0;
}

static void send_reply(conn_t *c, u32 status)
{
    wr32(c->reply, RFNET_MAGIC); wr32(c->reply + 4, status);
    if (tcp_write(c->pcb, c->reply, REPLY_LEN, TCP_WRITE_FLAG_COPY) == ERR_OK) {
        c->reply_pending = 0;
    } else {
        c->reply_pending = 1;          /* retried from the sent callback */
    }
    tcp_output(c->pcb);
}

/* stream the pending READ payload; called on first request and from the sent callback */
static void pump_tx(conn_t *c)
{
    if (c->reply_pending) {
        if (tcp_write(c->pcb, c->reply, REPLY_LEN, TCP_WRITE_FLAG_COPY) != ERR_OK) return;
        c->reply_pending = 0;
    }
    while (c->tx_left > 0) {
        u32 room = tcp_sndbuf(c->pcb);
        if (room == 0) break;
        u32 n = (c->tx_left < room) ? c->tx_left : room;
        if (n > 8192u) n = 8192u;                                    /* keep queue entries small */
        err_t e = tcp_write(c->pcb, c->tx_ptr, n, 0 /* no copy: data lives in DDR */);
        if (e != ERR_OK) break;                                       /* ERR_MEM: wait for sent */
        c->tx_ptr += n; c->tx_left -= n;
    }
    tcp_output(c->pcb);
    if (c->tx_left == 0 && !c->reply_pending && c->st == ST_SENDING) conn_reset_request(c);
}

/* commit a completed WRITE: flush caches (DDR) or word-copy the staged block (AXI) */
static u32 finish_write(conn_t *c)
{
    if (c->addr < DDR_LIMIT) {
        Xil_DCacheFlushRange((UINTPTR)c->addr, c->len);
        return XST_SUCCESS;
    }
    if ((c->addr & 3u) || (c->len & 3u)) return XST_FAILURE;
    for (u32 i = 0; i < c->len; i += 4) Xil_Out32(c->addr + i, rd32(stage_buf + i));
    return XST_SUCCESS;
}

static u32 run_exec(conn_t *c)
{
    if (c->len >= LINEMAX) return XST_FAILURE;
    c->exec_line[c->len] = '\0';
    xil_printf("\r\n[eth] %s\r\n", c->exec_line);
    return (u32)cli_runLine(c->exec_line);
}

/* consume `n` payload bytes at `p` for the current request; returns bytes consumed */
static u32 consume_payload(conn_t *c, const u8 *p, u32 n)
{
    u32 want = c->len - c->got;
    if (n > want) n = want;
    if (c->st == ST_WRITE_PAYLOAD) {
        if (c->addr < DDR_LIMIT) memcpy((void *)(UINTPTR)(c->addr + c->got), p, n);
        else                     memcpy(stage_buf + c->got, p, n);
    } else { /* ST_EXEC_PAYLOAD */
        memcpy(c->exec_line + c->got, p, n);
    }
    c->got += n;
    return n;
}

/* dispatch a fully received header */
static void start_request(conn_t *c)
{
    c->cmd  = rd32(c->hdr + 4);
    c->addr = rd32(c->hdr + 8);
    c->len  = rd32(c->hdr + 12);
    c->got  = 0;
    if (rd32(c->hdr) != RFNET_MAGIC) { xil_printf("[eth] bad magic\r\n"); tcp_abort(c->pcb); return; }

    switch (c->cmd) {
    case RFNET_CMD_PING:
        send_reply(c, XST_SUCCESS); conn_reset_request(c); break;
    case RFNET_CMD_WRITE:
        if (c->len == 0 || (c->addr >= DDR_LIMIT && c->len > STAGE_SIZE)) {
            send_reply(c, XST_FAILURE); conn_reset_request(c); break;
        }
        c->st = ST_WRITE_PAYLOAD; break;
    case RFNET_CMD_EXEC:
        if (c->len == 0 || c->len >= LINEMAX) { send_reply(c, XST_FAILURE); conn_reset_request(c); break; }
        c->st = ST_EXEC_PAYLOAD; break;
    case RFNET_CMD_READ:
        if (c->addr < DDR_LIMIT) Xil_DCacheInvalidateRange((UINTPTR)c->addr, c->len);
        c->tx_ptr = (const u8 *)(UINTPTR)c->addr; c->tx_left = c->len;
        c->st = ST_SENDING;
        send_reply(c, XST_SUCCESS);
        pump_tx(c);
        break;
    default:
        send_reply(c, XST_FAILURE); conn_reset_request(c); break;
    }
}

/* --------------------------------------------------------------------------
 * lwIP callbacks
 * ------------------------------------------------------------------------ */
static err_t on_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    conn_t *c = (conn_t *)arg;
    if (p == NULL) {                          /* remote closed */
        tcp_arg(pcb, NULL); tcp_recv(pcb, NULL); tcp_sent(pcb, NULL); tcp_err(pcb, NULL);
        tcp_close(pcb); c->pcb = NULL; conn_reset_request(c);
        xil_printf("[eth] connection closed\r\n");
        return ERR_OK;
    }
    if (err != ERR_OK) { pbuf_free(p); return err; }

    u32 total = p->tot_len;
    for (struct pbuf *q = p; q != NULL; q = q->next) {
        const u8 *d = (const u8 *)q->payload; u32 n = q->len;
        while (n > 0) {
            if (c->st == ST_HDR) {
                u32 k = HDR_LEN - c->hdr_got; if (k > n) k = n;
                memcpy(c->hdr + c->hdr_got, d, k); c->hdr_got += k; d += k; n -= k;
                if (c->hdr_got == HDR_LEN) start_request(c);
            } else if (c->st == ST_WRITE_PAYLOAD || c->st == ST_EXEC_PAYLOAD) {
                u32 k = consume_payload(c, d, n); d += k; n -= k;
                if (c->got == c->len) {
                    u32 status = (c->st == ST_WRITE_PAYLOAD) ? finish_write(c) : run_exec(c);
                    send_reply(c, status); conn_reset_request(c);
                }
            } else {                          /* ST_SENDING: host must not pipeline; drop */
                n = 0;
            }
        }
    }
    tcp_recved(pcb, total);
    pbuf_free(p);
    return ERR_OK;
}

static err_t on_sent(void *arg, struct tcp_pcb *pcb, u16_t len)
{
    (void)pcb; (void)len;
    conn_t *c = (conn_t *)arg;
    if (c->st == ST_SENDING || c->reply_pending) pump_tx(c);
    return ERR_OK;
}

static void on_err(void *arg, err_t err)
{
    conn_t *c = (conn_t *)arg;
    xil_printf("[eth] connection error %d\r\n", (int)err);
    c->pcb = NULL; conn_reset_request(c);
}

static err_t on_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    (void)arg;
    if (err != ERR_OK || newpcb == NULL) return ERR_VAL;
    if (conn.pcb != NULL) {                    /* one client at a time: the NEWEST client wins */
        /* A client that closed or crashed can leave its pcb here when its FIN was lost, and rejecting new clients
         * would then lock the server. Drop the stale connection instead: detach its callbacks first so that
         * tcp_abort() does not call on_err() on the connection state we are about to reuse. */
        struct tcp_pcb *old = conn.pcb;
        tcp_arg(old, NULL); tcp_recv(old, NULL); tcp_sent(old, NULL); tcp_err(old, NULL);
        tcp_abort(old);
        xil_printf("[eth] stale connection dropped for a new client\r\n");
    }
    memset(&conn, 0, sizeof(conn));
    conn.pcb = newpcb;
    tcp_arg(newpcb, &conn);
    tcp_recv(newpcb, on_recv);
    tcp_sent(newpcb, on_sent);
    tcp_err(newpcb, on_err);
    tcp_nagle_disable(newpcb);
    xil_printf("[eth] client connected\r\n");
    return ERR_OK;
}

/* --------------------------------------------------------------------------
 * bring-up
 * ------------------------------------------------------------------------ */
static void platform_setup_interrupts(void)
{
    XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    XScuGic_CfgInitialize(&xInterruptController, cfg, cfg->CpuBaseAddress);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
                                 (Xil_ExceptionHandler)XScuGic_InterruptHandler,
                                 &xInterruptController);
    Xil_ExceptionEnable();
}

int net_init(void)
{
    ip_addr_t ipaddr, netmask, gw;
    unsigned char mac[6] = { 0x00, 0x0a, 0x35, 0x00, 0x01, 0x22 };   /* locally administered */

    platform_setup_interrupts();
    lwip_init();

    IP4_ADDR(&ipaddr,  RFNET_IP0, RFNET_IP1, RFNET_IP2, RFNET_IP3);
    IP4_ADDR(&netmask, 255, 255, 255, 0);
    IP4_ADDR(&gw,      RFNET_IP0, RFNET_IP1, RFNET_IP2, RFNET_GW3);

    if (!xemac_add(&server_netif, &ipaddr, &netmask, &gw, mac, XPAR_XEMACPS_0_BASEADDR)) {
        xil_printf("[eth] xemac_add failed\r\n");
        return XST_FAILURE;
    }
    netif_set_default(&server_netif);
    netif_set_up(&server_netif);

    listen_pcb = tcp_new();
    if (listen_pcb == NULL) { xil_printf("[eth] tcp_new failed\r\n"); return XST_FAILURE; }
    if (tcp_bind(listen_pcb, IP_ADDR_ANY, RFNET_PORT) != ERR_OK) {
        xil_printf("[eth] bind failed\r\n"); return XST_FAILURE;
    }
    listen_pcb = tcp_listen(listen_pcb);
    tcp_accept(listen_pcb, on_accept);

    XTime_GetTime(&t_fast); t_slow = t_fast;
    xil_printf("[eth] server up: %d.%d.%d.%d:%d  MAC 00:0a:35:00:01:22\r\n",
               RFNET_IP0, RFNET_IP1, RFNET_IP2, RFNET_IP3, RFNET_PORT);
    return XST_SUCCESS;
}

void net_poll(void)
{
    static XTime t_rx = 0, t_link = 0;
    XTime now;
    xemacif_input(&server_netif);
    XTime_GetTime(&now);
    if (now - t_fast >= (COUNTS_PER_SECOND / 4)) { tcp_fasttmr(); t_fast = now; }   /* 250 ms */
    if (now - t_slow >= (COUNTS_PER_SECOND / 2)) { tcp_slowtmr(); t_slow = now; }   /* 500 ms */
    /* Xilinx template housekeeping: GEM RX-stall workaround every 100 ms, link poll every 1 s */
    if (now - t_rx   >= (COUNTS_PER_SECOND / 10)) { xemacpsif_resetrx_on_no_rxdata(&server_netif); t_rx = now; }
    if (now - t_link >=  COUNTS_PER_SECOND)       { eth_link_detect(&server_netif); t_link = now; }
}
