#include "mem.h"
#include "amd64.h"
#ifndef __ASSEMBLER__
#define __ASSEMBLER__
#endif

// N.B. on comments: /**/ are from the original NIX for the most part.
// // comments are mostly Harvey ca. 2020.

// This file is a pastiche of coreboot and NIX source, done in a way to get SOMETHING
// that would work in ATT syntax, as opposed to Plan 9 syntax. We took the opportunity
// to clean some things up. We broke Multiboot support for 5 years as a result.
// To fix multiboot, the code moves eax, ebp to edi, esi to match the calling convention.
// DO NOT USE edi and esi, or rdi and rsi, in any part of this code.
// Yes, there is a stack, but it's best not to count on it being more than 8 bytes deep.

// It gets REALLY ugly to try  to link this at some low address and then have the rest of the
// kernel linked high. Really, really ugly. And that defines any attempt to load at a random
// address. So, you have to learn to write position independent code here.
// It will make you stronger. Assuming you survive the training.
.code32

#define pFARJMP32(s, o)	.byte 0xea;	.long o; .word s	/* far jump to ptr32:16 */


/* do we enter in 16-bit mode? If so, take the code from coreboot that goes from
 * 16->32
 */
/*
 * Enter here in 32-bit protected mode. Welcome to 1982.
 * Make sure the GDT is set as it should be:
 *	disable interrupts;
 *	load the GDT with the table in _gdt32p;
 *	load all the data segments
 *	load the code segment via a far jump.
 */
#define MULTIBOOT_PAGE_ALIGN  (1<<0)
#define MULTIBOOT_MEMORY_INFO (1<<1)
#define MULTIBOOT_HEADER_MAGIC (0x1BADB002)
#define MULTIBOOT_HEADER_FLAGS (MULTIBOOT_MEMORY_INFO | MULTIBOOT_PAGE_ALIGN)
#define CHECKSUM (-(MULTIBOOT_HEADER_MAGIC + MULTIBOOT_HEADER_FLAGS))

# The kernel bootstrap (this code) is linked and loaded at physical address
# 0x00100000 (1MB), which is the start of extended memory.  (See kernel.ld)

# Flagging boottext to be text.  Check out:
# http://sourceware.org/binutils/docs/as/Section.html
.section .boottext, "awx"

.code32
.align 4
_protected:
multiboot_header:
.long MULTIBOOT_HEADER_MAGIC
.long MULTIBOOT_HEADER_FLAGS
.long CHECKSUM

	.globl _start
_start:
	cli
	jmp 1f


	/* This is the GDT for the ROM stage part of coreboot. It
	 * is different from the RAM stage GDT which is defined in
	 * c_start.S
	 */

	.align	4
.globl gdtptr
gdt:
gdtptr:
	.word	gdt_end - gdt -1 /* compute the table limit */
	.long	gdt		 /* we know the offset */
	.word	0

	/* selgdt 0x08, flat code segment */
	.word	0xffff, 0x0000
	.byte	0x00, 0x9b, 0xcf, 0x00 /* G=1 and 0x0f, So we get 4Gbytes for limit */

	/* selgdt 0x10,flat data segment */
	.word	0xffff, 0x0000
	.byte	0x00, 0x93, 0xcf, 0x00

	/* long mode code segment. */
	.quad	0x0020980000000000		/* Long mode CS */

gdt_end:


/*
 *	When we come here we are in protected mode. We expand
 *	the stack and copies the data segment from ROM to the
 *	memory.
 *
 *	After that, we call the chipset bootstrap routine that
 *	does what is left of the chipset initialization.
 *
 *	NOTE aligned to 4 so that we are sure that the prefetch
 *	cache will be reloaded.
 */
	.align	4
1:
//	jmp 1b
.globl protected_start
protected_start:

	lgdt	%cs:gdtptr
	ljmp	$8, $__protected_start

__protected_start:
	// Save the multiboot args rdi,rsi; this matches
	// the calling convention.
	movl	%eax, %edi
	movl	%ebx, %esi
	movw	$0x10, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	movw	%ax, %fs
	movw	%ax, %gs

	/* Restore the BIST value to %eax */
	movl	%ebp, %eax

entry32:
1:
	movb	$0x30, %al
	movw $0x30, %dx
	outb %dx
// This gets us into a reasonable mode. We can skip the plan 9 gdt code.
	call 1f
1:
	popl	%ebp
	/* when you execute this instruction, bp has the value
	 * of 1f.
	 * So add the length of this instruction and the
	 * 5 bytes of the jmp that follows it.
	 * It will then point to start of header.
	 */
	addl $12, %ebp
	/* Now make it point to gdt32p (gdt, 32 bits, physical)
	 */
	addl $14, %ebp
	JMP _endofheader

_startofheader:
	.byte	0x90				/* NOP */
	.byte	0x90				/* NOP */

_multibootheader:	/* must be 4-byte aligned */
	.long	0x1badb002			/* magic */
	.long	0x00000003			/* flags */
	.long	-(0x1badb002 + 0x00000003)	/* checksum */

_gdt32p:
	.quad	0x0000000000000000		/* NULL descriptor */
	.quad	0x00cf9a000000ffff		/* CS */
	.quad	0x00cf92000000ffff		/* DS */
	.quad	0x0020980000000000		/* Long mode CS */

_gdtptr32p:
	.word	4*8-1
	.long	_gdt32p

_gdt64p:
	.quad	0x0000000000000000		/* NULL descriptor */
	.quad	0x0020980000000000		/* CS */

_gdtptr64p:
	.word	2*8-1
	.quad	_gdt64p


_endofheader:
	pushl %eax				/* possible passed-in magic */

/*
 * Make the basic page tables for CPU0 to map 0-16MiB physical
 * to KZERO, and include an identity map for the switch from protected
 * to paging mode. There's an assumption here that the creation and later
 * removal of the identity map will not interfere with the KZERO mappings;
 * the conditions for clearing the identity map are
 *	clear PML4 entry when (KZER0 & 0x0000ff8000000000) != 0;
 *	clear PDP entry when (KZER0 & 0x0000007fc0000000) != 0;
 *	don`t clear PD entry when (KZER0 & 0x000000003fe00000) == 0;
 * the code below assumes these conditions are met.
 *
 * Assume a recent processor with Page Size Extensions
 * and use two 2MiB entries.
 */
/*
 * The layout is decribed in data.h:
 *	_protected:	start of kernel text
 *	- 4*KiB		unused
 *	- 4*KiB		unused
 *	- 4*KiB		ptrpage
 *	- 4*KiB		syspage
 *	- MACHSZ	m
 *	- 4*KiB		vsvmpage for gdt, tss
 *	- PTSZ		PT for PMAPADDR		unused - assumes in KZERO PD
 *	- PTSZ		PD
 *	- PTSZ		PDP
 *	- PTSZ		PML4
 *	- MACHSTKSZ	stack
 */

/*
 * Macros for accessing page table entries; change the
 * C-style array-index macros into a page table byte offset
 */
#define PML4O(v)	((PTLX((v), 3))<<3)
#define PDPO(v)		((PTLX((v), 2))<<3)
#define PDO(v)		((PTLX((v), 1))<<3)
#define PTO(v)		((PTLX((v), 0))<<3)

_warp64:
	// WARNING edi and esi usage
	// We use the stosl below, which requires esi and edi.
	// We need to save them, and we can not use eax or ecx.
	// We can, however, use edx and ebp; do so.
	movl	%edi, %edx
	// NO CALL OR PUSH/POP AFTER THIS POINT.
	movl 	%esi, %esp
	movl	$_protected-(MACHSTKSZ+4*PTSZ+5*(4*KiB)+MACHSZ/*+KZERO*/), %esi

	// Don't zero the lowest two pages, they typically contain
	// multiboot info. TODO: don't zero the stack. Code that depends
	// on stack variables being zero'd is buggy by definition.
	movl	%esi, %edi
	addl    $8192, %edi
	xorl	%eax, %eax
	movl	$((MACHSTKSZ+4*PTSZ+5*(4*KiB)+MACHSZ)>>2), %ecx
	subl    $2048, %ecx

	cld
	rep;	stosl				/* stack, P*, vsvm, m, sys */
	movl	%esi, %eax			/* sys-KZERO */

	movl	%edx, %edi
	// END WARNING edi usage.
	// ESI is still used!
	// NO CALL OR PUSH/POP UNTIL rsp IS LOADED BELOW
	addl	$(MACHSTKSZ), %eax		/* PML4 */
	movl	%eax, %CR3			/* load the mmu */
	movl	%eax, %edx
	addl	$(PTSZ|PteRW|PteP), %edx	/* PDP at PML4 + PTSZ */
	movl	%edx, PML4O(0)(%eax)		/* PML4E for identity map */
	movl	%edx, PML4O(KZERO)(%eax)	/* PML4E for KZERO, PMAPADDR */

	addl	$PTSZ, %eax			/* PDP at PML4 + PTSZ */
	addl	$PTSZ, %edx			/* PD at PML4 + 2*PTSZ */
	movl	%edx, PDPO(0)(%eax)		/* PDPE for identity map */
	movl	%edx, PDPO(KZERO)(%eax)		/* PDPE for KZERO, PMAPADDR */

	addl	$PTSZ, %eax				/* PD at PML4 + 2*PTSZ */
	movl	$(PtePS|PteRW|PteP), %edx
	movl	%edx, PDO(0)(%eax)			/* PDE for identity 0-2MiB */
	movl	%edx, PDO(KZERO)(%eax)			/* PDE for KZERO 0-2MiB */
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+1*PGLSZ(1))(%eax)	/* PDE for KZERO 4-6MiB */
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+2*PGLSZ(1))(%eax)	/* PDE for KZERO 4-6MiB */
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+3*PGLSZ(1))(%eax)	/* PDE for KZERO 6-8MiB */

	// and up through 12 (and on to 16). This sucks, we'll make it better later. //
	// We'll just have init the pml2 at compile time. Apologies.
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+4*PGLSZ(1))(%eax)	/* PDE for KZERO 8-10MiB */
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+5*PGLSZ(1))(%eax)	/* PDE for KZERO 10-12MiB */
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+6*PGLSZ(1))(%eax)	/* PDE for KZERO 12-14MiB */
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+7*PGLSZ(1))(%eax)	/* PDE for KZERO 14-16MiB */

	movl	%eax, %edx			/* PD at PML4 + 2*PTSZ */
	addl	$(PTSZ|PteRW|PteP), %edx	/* PT at PML4 + 3*PTSZ */
	movl	%edx, PDO(PMAPADDR)(%eax)	/* PDE for PMAPADDR */

/*
 * Enable and activate Long Mode. From the manual:
 * 	make sure Page Size Extentions are off, and Page Global
 *	Extensions and Physical Address Extensions are on in CR4;
 *	set Long Mode Enable in the Extended Feature Enable MSR;
 *	set Paging Enable in CR0;
 *	make an inter-segment jump to the Long Mode code.
 * It`s all in 32-bit mode until the jump is made.
 */
lme:
	movl	%cr4, %eax
	ANDL	$~Pse, %eax			/* Page Size */
	ORL	$(Pge|Pae), %eax		/* Page Global, Phys. Address */
	movl	%eax, %cr4

	movl	$Efer, %ecx			/* Extended Feature Enable */
	RDMSR
	ORL	$Lme, %eax			/* Long Mode Enable */
	WRMSR

	movl	%cr0, %edx
	ANDL	$~(Cd|Nw|Ts|Mp), %edx
	ORL	$(Pg|Wp), %edx			/* Paging Enable */
	movl	%edx, %cr0
	ljmp $0x18, $_identity
	//pFARJMP32(SSEL(3, SsTIGDT|SsRPL0), _identity-KZERO)

/*
 * Long mode. Welcome to 2003.
 * Jump out of the identity map space;
 * load a proper long mode GDT.
 */
.code64

_identity:
	movq	$_start64v, %rax
	JMP	*%rax
.section .text
_gdt64v:
	.quad	0x0000000000000000		/* NULL descriptor */
	.quad	0x0020980000000000		/* CS */

_gdtptr64v:
	.word	3*8-1
	.quad	_gdt64v

// At this point, we are safe to use kernel addresses, as we are in
// kernel virtual address space.
_start64v:
	movq	$_gdtptr64v, %rax
	lgdt	(%rax)

	XORQ	%rdx, %rdx
	movw	%dx, %ds			/* not used in long mode */
	movw	%dx, %es			/* not used in long mode */
	movw	%dx, %fs
	movw	%dx, %gs
	movw	%dx, %ss			/* not used in long mode */

	movq	%rsi, %rsi			/* sys-KZERO */
	movq	%rsi, %rax
	addq	$KZERO, %rax
	movq	%rax, sys			/* sys */

	addq	$(MACHSTKSZ), %rax		/* PML4 and top of stack */
	// put multiboot args back.
	// NO USE OF rbp PAST THIS POINT.
	movq	%rsp, %rbp
	movq	%rax, %rsp			/* set stack */
	// YOU CAN NOW USE THE STACK AGAIN.

// Don't undo this until all APs are started. Then we don't need to bother
// having the APs remap it. Save work.
	// OK, this part is called "we climbed up the tree on a ladder, now pull
	// the ladder up after us.". We remove the identity mapping.
_zap0pml4:
	cmpq	$PML4O(KZERO), %rdx		/* KZER0 & 0x0000ff8000000000 */
	JE	_zap0pdp
	//movq	%rdx, PML4O(0)(%rax) 		/* zap identity map PML4E */
_zap0pdp:
	addq	$PTSZ, %rax			/* PDP at PML4 + PTSZ */
	cmpq	$PDPO(KZERO), %rdx 		/* KZER0 & 0x0000007fc0000000 */
	JE	_zap0pd
	//movq	%rdx, PDPO(0)(%rax)		/* zap identity map PDPE */
_zap0pd:
	addq	$PTSZ, %rax			/* PD at PML4 + 2*PTSZ */
	cmpq	$PDO(KZERO), %rdx		/* KZER0 & 0x000000003fe00000 */
	JE	_zap0done
	//movq	%rdx, PDO(0)(%rax)		/* zap identity map PDE */
_zap0done:
	// now for the scary part. In some sense, all page table zapping to date
	// has been theoretical. This is going to flush it. If we survive this ...

	addq	$(MACHSTKSZ), %rsi		/* PML4-KZERO */
	movq	%rsi, %CR3			/* flush TLB */

	addq	$(2*PTSZ+4*KiB), %rax		/* PD+PT+vsvm */
	movq	%rax, entrym
	movq	$0, (%rax) 			/* machp()->machno = 0 */

	PUSHQ	%rdx				/* clear flags */
	POPFQ

	movq	%rbp, %rsi			/* expand multiboot args to 64 bits */
	movq	%rdi, %rdi			/* multiboot magic */
	CALL	main

.globl ndnr
ndnr:	/* no deposit, no return */
	/* do not resuscitate */
_dnr:
	sti
	hlt
	JMP	_dnr				/* do not resuscitate */

	// SIPI startup handler. The first bits of this code, which are 16-bit, are copied
	// to 0x3000. That code jumps to the 32-bit entry point right after the lgdt, which is in
	// the normal place, no need to copy it. If this works, it's a lot more compact
	// than what Plan 9 used to do.
	/*
 * Start-up request IPI handler.
 *
 * This code is executed on an application processor in response to receiving
 * a Start-up IPI (SIPI) from another processor.
 * This must be placed on a 4KiB boundary
 * somewhere in the 1st MiB of conventional memory. However,
 * due to some shortcuts below it's restricted further to within the 1st 64KiB.
 * The AP starts in real-mode, with
 *   CS selector set to the startup memory address/16;
 *   CS base set to startup memory address;
 *   CS limit set to 64KiB;
 *   CPL and IP set to 0.
 */

/*
 * Real mode. Welcome to 1978.
 * Load a basic GDT, turn on protected mode and make
 * inter-segment jump to the protected mode code.
 */
	.align 4096
.code32
.globl b1978
b1978:
_sipistartofheader:
	NOP; NOP; NOP
	.quad	0xa5a5a5a5a5a5a5a5
// real mode gdt located in low 64k
// GOT TO THIS LOOP
//1: jmp 1b
	// clang stupidity. Or smartness. It can't do .code16!
	.byte 0xfa //cli
	.byte 0x66, 0x31, 0xc0 //xorl	%eax, %eax
	.byte 0x0f, 0x22, 0xd8 // movl	%eax, %cr3 // invalidate tlb
	.byte 0x8e, 0xd8 //movw	%ax, %ds
	.byte 0x8c, 0xc8 // movw	%cs, %ax
	.byte 0xbb, 0x80, 0x30 //movw	$0x3080, %bx
	.byte 0x67, 0x66, 0x0f, 0x01, 0x13 // data32 lgdt (%ebx)

	.byte 0x0f, 0x20, 0xc0 //movl	%cr0, %eax
	.byte 0x66, 0x25, 0xd1, 0xff, 0xfa, 0x7f // andl	$0x7FFAFFD1, %eax /* PG,AM,WP,NE,TS,EM,MP = 0 */
	.byte 0x66, 0x0d, 0x01, 0x00, 0x00, 0x60 // orl	$0x60000001, %eax /* CD, NW, PE = 1 */
	.byte 0x0f, 0x22, 0xc0 // movl	%eax, %cr0

	//ljmpl $8, $0x3040
	.byte 0x66, 0xea // ljmpl, 066 prefix since we're 16 bits
	.byte 0x40, 0x30, 0x00, 0x00 // 32 bit offset
	.byte 0x08, 0x00 // 16 bit segment
.align 32

.code32
	movw	$0x10, %ax
	MOVW	%AX, %DS
	MOVW	%AX, %ES
	MOVW	%AX, %FS
	MOVW	%AX, %GS
	MOVW	%AX, %SS
	/* Now that we are in protected mode jump to a 32 bit code segment. */
	ljmpl	$8, $_approtected
.align	64
gdt78:
gdtptr78:
	.word	4*8-1
	.long 0x3080 // $gdt78-$b1978
	.word 0 // unused
	/* selgdt 0x08, flat code segment */
	.word	0xffff, 0x0000
	.byte	0x00, 0x9b, 0xcf, 0x00 /* G=1 and 0x0f, So we get 4Gbytes for limit */

	/* selgdt 0x10,flat data segment */
	.word	0xffff, 0x0000
	.byte	0x00, 0x93, 0xcf, 0x00
	.quad	0x0020980000000000		/* Long mode CS */
gdt78_end:
.global e1978
e1978:

/*
 * Protected mode. Welcome to 1982.
 * Get the local APIC ID from the memory mapped APIC;
#ifdef UseOwnPageTables
 * load the PDB with the page table address, which is located
 * in the word immediately preceeding _real<>-KZERO(SB);
 * this is also the (physical) address of the top of stack;
#else
 * load the PML4 with the shared page table address;
#endif
 * make an identity map for the inter-segment jump below,
 * using the stack space to hold a temporary PDP and PD;
 * enable and activate long mode;
 * make an inter-segment jump to the long mode code.
 */
.section .boottext, "awx"
.code32

/*
 * Macros for accessing page table entries; must turn
 * the C-style array-index macros into a page table byte
 * offset.
 */
#define PML4O(v)	((PTLX((v), 3))<<3)
#define PDPO(v)		((PTLX((v), 2))<<3)
#define PDO(v)		((PTLX((v), 1))<<3)
#define PTO(v)		((PTLX((v), 0))<<3)

_approtected:
	MOVL	$0xfee00000, %ebp	/* apicbase */
	MOVL	0x20(%eBP), %eBP	/* Id */
	SHRL	$24, %eBP		/* becomes RARG later */

#ifdef UseOwnPageTables
	MOVL	$_real<>-KZERO(SB), AX
	MOVL	-4(AX), %eSI			/* page table PML4 */
#else
	MOVL	$(0x00100000+MACHSTKSZ), %eSI	/* page table PML4 */
#endif
	// endif before
	MOVL	%eSI, %eAX
	MOVL	%eAX, %CR3			/* load the mmu */
#if 0
	MOVL	%eAX, %eDX
	SUBL	$MACHSTKSZ, %eDX		/* PDP for identity map */
	ADDL	$(PteRW|PteP), %eDX
	MOVL	%eDX, PML4O(0)(%eAX)		/* PML4E for identity map */

	SUBL	$MACHSTKSZ, %eAX		/* PDP for identity map */
	ADDL	$PTSZ, %eDX
	MOVL	%eDX, PDPO(0)(%eAX)		/* PDPE for identity map */
	MOVL	$(PtePS|PteRW|PteP), %edX
	ADDL	$PTSZ, %eAX			/* PD for identity map */
	MOVL	%eDX, PDO(0)(%eAX)		/* PDE for identity 0-[24]MiB */
#endif

/*
 * Enable and activate Long Mode. From the manual:
 * 	make sure Page Size Extentions are off, and Page Global
 *	Extensions and Physical Address Extensions are on in CR4;
 *	set Long Mode Enable in the Extended Feature Enable MSR;
 *	set Paging Enable in CR0;
 *	make an inter-segment jump to the Long Mode code.
 * It's all in 32-bit mode until the jump is made.
 */
aplme:
	MOVL	%CR4, %eAX
	ANDL	$~Pse, %eAX			/* Page Size */
	ORL	$(Pge|Pae), %eAX		/* Page Global, Phys. Address */
	MOVL	%eAX, %CR4

	MOVL	$Efer, %eCX			/* Extended Feature Enable */
	RDMSR
	ORL	$Lme, %eAX			/* Long Mode Enable */
	WRMSR

	MOVL	%CR0, %eDX
	ANDL	$~(Cd|Nw|Ts|Mp), %eDX
	ORL	$(Pg|Wp), %eDX			/* Paging Enable */
	MOVL	%eDX, %CR0

	ljmp $0x18, $_apidentity

/*
 * Long mode. Welcome to 2003.
 * Jump out of the identity map space;
 * load a proper long mode GDT;
 * zap the identity map;
 * initialise the stack and call the
 * C startup code in m->splpc.
 */
.code64

_apidentity:
	MOVQ	$_apstart64v, %rAX
	JMP	*%rAX

.section .text
_apstart64v:
	MOVQ	$_gdtptr64v, %rAX

	lgdt	(%rax)
	XORQ	%rDX, %rDX
	MOVW	%DX, %DS			/* not used in long mode */
	MOVW	%DX, %ES			/* not used in long mode */
	MOVW	%DX, %FS
	MOVW	%DX, %GS
	MOVW	%DX, %SS			/* not used in long mode */

	movq	%rsi, %rsi			/* PML4-KZERO */
	MOVQ	%rsI, %rAX
	ADDQ	$KZERO, %rAX			/* PML4 and top of stack */

	MOVQ	%rAX, %rSP			/* set stack */

	// DON'T ZAP.
	// DO IT LATER.
	//MOVQ	%rDX, PML4O(0)(%rAX)		/* zap identity map */

	MOVQ	%rSI, %CR3			/* flush TLB */
#ifndef UseOwnPageTables
	/*
	 * SI still points to the base of the bootstrap
	 * processor page tables.
	 * Want to use that for clearing the identity map,
	 * but want to use the passed-in address for
	 * setting up the stack and Mach.
	 */
	// oh, barf.
//	MOVQ	$_real, %rAX
	MOVQ	$0x3000, %rAX
	MOVL	-4(%rAX), %eSI			/* PML4 */
	MOVq	%rSI, %rSI			/* PML4-KZERO */
#endif
	MOVQ	%rSI, %rAX
	ADDQ	$KZERO, %rAX			/* PML4 and top of stack */

	MOVQ	%rAX, %rSP			/* set stack */

	PUSHQ	%rDX				/* clear flags */
	POPFQ

	// put this in %rdx so it can be the third argument. We need to write it into
	// %gs
	ADDQ	/*$4*PTSZ+$4*KiB*/$0x5000, %raX	/* PML4+PDP+PD+PT+vsvm */
	MOVq	%rbp, %rdi			/* APIC ID */
	movq	%rax, %rsi			/* Mach * */

	MOVQ	8(%rsi), %rAX			/* m->splpc */
	xorq	%rbp, %rbp			/* stack trace ends here */
	CALL	*%raX				/* CALL squidboy(SB) */
