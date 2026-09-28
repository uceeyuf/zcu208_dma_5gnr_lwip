/*
 * cap_dma.c
 *
 *  Created on: Nov 12, 2019
 *      Author: jakobc
 */
/***************************** Include Files *********************************/
#include "cap_dma.h"

#include "xil_io.h"
#include "xil_types.h"
#include <stdio.h>
#include "cli.h"
#include "xparameters.h"
#include "main.h"
#include "xaxidma.h"
#include "xil_mmu.h"


/************************** Constant Definitions *****************************/

// Define used to switch between assignment of dma BD and buffer space using
// defines or using linkerscript sections
#define RX_USE_LNK_ASSIGNMENTS 1

// Device hardware build related constants.
#define DMA_DEV_ID			XPAR_AXI_DMA_ADC_DEVICE_ID

#define GPIO_ADC_BASE 		XPAR_AXI_GPIO_ADC_BASEADDR

#define FIFO_RST_BIT			0x1

// Define DDR address map. Linkerscript has been modified to carve out
// following memory usage. Make sure there are no overlaps with other
// sections of code such as a TX DMA
#if RX_USE_LNK_ASSIGNMENTS == 0
#define MEM_BASE_ADDR		(XPAR_PSU_DDR_0_S_AXI_BASEADDR)
#define RX_BD_SPACE_BASE	(MEM_BASE_ADDR + 0x00100000)
#define RX_BD_SPACE_HIGH	(MEM_BASE_ADDR + 0x00100FFF)
#define RX_BUFFER_BASE		(MEM_BASE_ADDR + 0x00101000)
#define RX_BUFFER_HIGH		(MEM_BASE_ADDR + 0x3FFFFFFF)
#endif

#define MARK_UNCACHEABLE    (NORM_NONCACHE | INNER_SHAREABLE)


/**************************** Type Definitions *******************************/

/***************** Macros (Inline Functions) Definitions *********************/

/************************** Function Prototypes ******************************/

/************************** Variable Definitions *****************************/

// values that hold dma BD and buffer address info. Define RX_USE_LNK_ASSIGNMENTS
// switches between using absolute addresses from previous defines or using
// values from section assignments in the linker script lscript.ld

#if RX_USE_LNK_ASSIGNMENTS == 0
UINTPTR rx_bd_base  = RX_BD_SPACE_BASE;
UINTPTR rx_bd_high  = RX_BD_SPACE_HIGH;
UINTPTR rx_buf_base = RX_BUFFER_BASE;
UINTPTR rx_buf_high = RX_BUFFER_HIGH;
#else

extern const UINTPTR _rx_bd_space_start;
extern const UINTPTR _rx_bd_space_end;
extern const UINTPTR _rx_buf_space_start;
extern const UINTPTR _rx_buf_space_end;

const UINTPTR rx_bd_base  = (UINTPTR)&_rx_bd_space_start;
const UINTPTR rx_bd_high  = (UINTPTR)&_rx_bd_space_end;
const UINTPTR rx_buf_base = (UINTPTR)&_rx_buf_space_start;
const UINTPTR rx_buf_high = (UINTPTR)&_rx_buf_space_end;

#endif


/************************** Function Definitions ******************************/


/*****************************************************************************/
/**
*
* cli_cap_dma_init Add functions from this file to CLI
*
* @param	None
*
* @return	None
*
* @note		TBD
*
******************************************************************************/
void cli_cap_dma_init(void)
{
	static CMDSTRUCT cliCmds[] = {
		//000000000011111111112222    000000000011111111112222222222333333333
		//012345678901234567890123    012345678901234567890123456789012345678
    	{"###################### ADC DMA #########################", " "	 , 0, *cmdComment},
		{"adcCapture"              , "<numKB> - initiate ADC capture"        , 1, *adcCapture},
		{" "                       , " "                                     , 0, *cmdComment},
	};

	cli_addCmds(cliCmds, sizeof(cliCmds)/sizeof(cliCmds[0]));
}


/*****************************************************************************/
/**
*
* RxSetup used by capture function to initialize the DMA buffer descriptors
* and start the RX DMA
*
* @param	None
*
* @return	None
*
* @note		TBD
*
******************************************************************************/
static int RxSetup(XAxiDma * AxiDmaInstPtr, u32 BdCount, u32 BytesPerBd, UINTPTR *BdLastPtr)
{
	XAxiDma_Bd BdTemplate;
	XAxiDma_Bd *BdPtr;
	u32 FreeBdCount;
	UINTPTR RxBufferPtr;
	int Index;
	int Status;
	XAxiDma_Bd *BdCurPtr;
	XAxiDma_BdRing *RxRingPtr;

	RxRingPtr = XAxiDma_GetRxRing(AxiDmaInstPtr);

	Status = XAxiDma_BdRingCreate(RxRingPtr, rx_bd_base, rx_bd_base,
				XAXIDMA_BD_MINIMUM_ALIGNMENT, BdCount);

	if (Status != XST_SUCCESS) {
		xil_printf("RX create BD ring failed %d\r\n", Status);

		return XST_FAILURE;
	}

	/*
	 * Setup an all-zero BD as the template for the Rx channel.
	 */
	XAxiDma_BdClear(&BdTemplate);

	Status = XAxiDma_BdRingClone(RxRingPtr, &BdTemplate);
	if (Status != XST_SUCCESS) {
		xil_printf("RX clone BD failed %d\r\n", Status);

		return XST_FAILURE;
	}

	/* Attach buffers to RxBD ring so we are ready to receive packets */

	FreeBdCount = XAxiDma_BdRingGetFreeCnt(RxRingPtr);

	Status = XAxiDma_BdRingAlloc(RxRingPtr, FreeBdCount, &BdPtr);
	if (Status != XST_SUCCESS) {
		xil_printf("RX alloc BD failed %d\r\n", Status);

		return XST_FAILURE;
	}

	BdCurPtr = BdPtr;
	RxBufferPtr = rx_buf_base;
	for (Index = 0; Index < FreeBdCount; Index++) {
		Status = XAxiDma_BdSetBufAddr(BdCurPtr, RxBufferPtr);

		if (Status != XST_SUCCESS) {
			xil_printf("Set buffer addr 0x%p on BD %x failed %d\r\n",
			    (unsigned int)RxBufferPtr,
			    (UINTPTR)BdCurPtr, Status);

			return XST_FAILURE;
		}

		Status = XAxiDma_BdSetLength(BdCurPtr, BytesPerBd,
				RxRingPtr->MaxTransferLen);
		if (Status != XST_SUCCESS) {
			xil_printf("Rx set length %d on BD %x failed %d\r\n",
					BytesPerBd, (UINTPTR)BdCurPtr, Status);

			return XST_FAILURE;
		}

		XAxiDma_BdSetCtrl(BdCurPtr, 0);
		XAxiDma_BdSetId(BdCurPtr, RxBufferPtr);
		/* clear the buffer memory pointed to by this bd */
		//memset((void *)RxBufferPtr, 0, BytesPerBd);

		RxBufferPtr += BytesPerBd;
		if (Index != FreeBdCount - 1) { //don't run on last iteration (preserves last Bd address in BdCurPtr)
			BdCurPtr = (XAxiDma_Bd *)XAxiDma_BdRingNext(RxRingPtr, BdCurPtr);
		}
	}

	Status = XAxiDma_BdRingToHw(RxRingPtr, FreeBdCount,
						BdPtr);
	if (Status != XST_SUCCESS) {
		xil_printf("RX submit hw failed %d\r\n", Status);

		return XST_FAILURE;
	}

	/* Start RX DMA channel */
	Status = XAxiDma_BdRingStart(RxRingPtr);
	if (Status != XST_SUCCESS) {
		xil_printf("RX start hw failed %d\r\n", Status);

		return XST_FAILURE;
	}

	// Pass last BD ptr to function caller
	*BdLastPtr = (UINTPTR)BdCurPtr;
	return XST_SUCCESS;
}


/*****************************************************************************/
/**
*
* capture: Calculates the values for the buffer descriptors, starts the DMA
* and then monitors the last buffer descriptor until it is complete. This
* polling removes the requirement for TLAST which normally triggers completion
* of the dma transaction.
*
* @param	None
*
* @return	None
*
* @note		TBD
*
******************************************************************************/
void adcCapture (u32 *cmdVals)
{
	int Status;
	XAxiDma_Config *Config;
	XAxiDma rxAxiDma;
	u32 BdCount;
	u32 BytesPerBd;
	UINTPTR BdLastPtr=0;
	XAxiDma_BdRing *RxRingPtr;
	u32 NumBytes;
	u32 tmpVal;

	NumBytes = cmdVals[0] * 1024;

	// mark BD space as uncachable with a resolution of 2MB per addr
	Xil_SetTlbAttributes(rx_bd_base, MARK_UNCACHEABLE);

	Config = XAxiDma_LookupConfig(DMA_DEV_ID);
	if (!Config) {
		xil_printf("No config found for %d\r\n", DMA_DEV_ID);

		return;
	}

	// Put FIFO in reset (important to do this before DMA init to avoid unwanted data)
	tmpVal = Xil_In32(GPIO_ADC_BASE);
	tmpVal = tmpVal & ~FIFO_RST_BIT;		//clear bits to assert aresetn
	Xil_Out32(GPIO_ADC_BASE, tmpVal);

	/* Initialize DMA engine */
	XAxiDma_CfgInitialize(&rxAxiDma, Config);

	RxRingPtr = XAxiDma_GetRxRing(&rxAxiDma);

	if (NumBytes < 0x1000)
	{
		NumBytes = 0x1000;
		xil_printf("Warning: number of bytes must be at least 4K. Rounding up.\r\n");
	}
	if (NumBytes > (rx_buf_high - rx_buf_base + 1)) {
		NumBytes = rx_buf_high - rx_buf_base + 1;
		xil_printf("Warning: exceeded RX buffer memory space. Reducing to max.\r\n");
	}
	if (NumBytes % 0x1000 != 0) {
		xil_printf("Warning: number of bytes must be 4K aligned. Rounding down.\r\n");
		NumBytes &= ~0xFFF;
	}

	BdCount = (((NumBytes + (RxRingPtr->MaxTransferLen) - 1)) / (RxRingPtr->MaxTransferLen));
	while (NumBytes % BdCount != 0) {
		BdCount++;
	}
	if (BdCount > XAxiDma_BdRingCntCalc(XAXIDMA_BD_MINIMUM_ALIGNMENT, rx_bd_high - rx_bd_base + 1)) {
		xil_printf("Error: exceeded buffer descriptor memory space. Try transmitting less bytes.\r\n");
		return;
	}
	BytesPerBd = NumBytes / BdCount;
	xil_printf("Transferring %d bytes to memory location 0x%p\r\n", NumBytes, rx_buf_base);

	Status = RxSetup(&rxAxiDma, BdCount, BytesPerBd, &BdLastPtr);
	if (Status != XST_SUCCESS) {
		xil_printf("Error: RxSetup() Failed\r\n");
		return;
	}

	// Remove reset on FIFO
	tmpVal = Xil_In32(GPIO_ADC_BASE);
	tmpVal = tmpVal | FIFO_RST_BIT;		//set bits to deassert aresetn
	Xil_Out32(GPIO_ADC_BASE, tmpVal);

	//wait for complete bit on last Bd
	while (!XAxiDma_BdHwCompleted((XAxiDma_Bd *)BdLastPtr)) {
		;
	}

	// Put FIFO in reset
	tmpVal = Xil_In32(GPIO_ADC_BASE);
	tmpVal = tmpVal & ~FIFO_RST_BIT;		//clear bits to assert aresetn
	Xil_Out32(GPIO_ADC_BASE, tmpVal);

	XAxiDma_Reset(&rxAxiDma); 														//reset DMA

	return;
}

