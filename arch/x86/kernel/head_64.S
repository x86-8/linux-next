/*
 *  linux/arch/x86_64/kernel/head.S -- start in 32bit and switch to 64bit
 *
 *  Copyright (C) 2000 Andrea Arcangeli <andrea@suse.de> SuSE
 *  Copyright (C) 2000 Pavel Machek <pavel@suse.cz>
 *  Copyright (C) 2000 Karsten Keil <kkeil@suse.de>
 *  Copyright (C) 2001,2002 Andi Kleen <ak@suse.de>
 *  Copyright (C) 2005 Eric Biederman <ebiederm@xmission.com>
 */


#include <linux/linkage.h>
#include <linux/threads.h>
#include <linux/init.h>
#include <asm/segment.h>
#include <asm/pgtable.h>
#include <asm/page.h>
#include <asm/msr.h>
#include <asm/cache.h>
#include <asm/processor-flags.h>
#include <asm/percpu.h>
#include <asm/nops.h>

#ifdef CONFIG_PARAVIRT
#include <asm/asm-offsets.h>
#include <asm/paravirt.h>
#define GET_CR2_INTO(reg) GET_CR2_INTO_RAX ; movq %rax, reg
#else
#define GET_CR2_INTO(reg) movq %cr2, reg
#define INTERRUPT_RETURN iretq
#endif

/*
 * 이 코드는 페이징, 플래그등에 대한 몇가지 작업을 한다.
 */

/* we are not able to switch in one step to the final KERNEL ADDRESS SPACE
 * because we need identity-mapped pages.
 *
 */
/* pud_index는 shift와 mask로 몇번째 pud인지를 구한다. */
#define pud_index(x)	(((x) >> PUD_SHIFT) & (PTRS_PER_PUD-1))

/* 0xffff88000... */
L4_PAGE_OFFSET = pgd_index(__PAGE_OFFSET)
L3_PAGE_OFFSET = pud_index(__PAGE_OFFSET)
/* 0xffffffff80000000 */
L4_START_KERNEL = pgd_index(__START_KERNEL_map)
L3_START_KERNEL = pud_index(__START_KERNEL_map)

	.text
	__HEAD 						/* .head.text */
	.code64
	.globl startup_64
startup_64:

	/*
	 * CS.L=1, CS.D=1은 주석 오류라고 추측한다.
	 * 이러면 GP fault가 발생한다.
	 * 
	 * At this point the CPU runs in 64bit mode CS.L = 1 CS.D = 1,
	 * and someone has loaded an identity mapped page table
	 * for us.  These identity mapped page tables map all of the
	 * kernel pages and possibly all of memory.
	 *
	 * %esi holds a physical pointer to real_mode_data.
	 *
	 * We come here either directly from a 64bit bootloader, or from
	 * arch/x86_64/boot/compressed/head.S.
	 *
	 * We only come here initially at boot nothing else comes here.
	 *
	 * Since we may be loaded at an address different from what we were
	 * compiled to run at we first fixup the physical addresses in our page
	 * tables and then reload them.
	 */

	/* 압축풀린 커널 부분의 시작 */
	/* Compute the delta between the address I am compiled to run at and the
	 * address I am actually running at.
	 */

	/* 실행중인 코드 시작부분이 될 것이다. */
	leaq	_text(%rip), %rbp

	/* $_text는 VMA의 direct mapping구역 + 16M 이 될 것이다. */
	subq	$_text - __START_KERNEL_map, %rbp

	/*
	 * 0xffffffff80000000은 +-해서 사라지고 16M이 남는다.
	 * 실행중인 메모리 위치에서 16M을 빼주면 보통 0이 된다.
	 * 결론은 실행중인 위치와 컴파일시 위치의 갭을 구한다.
	 */

	/* Is the address not 2M aligned? */
	movq	%rbp, %rax
	andl	$~PMD_PAGE_MASK, %eax /* 2M 아랫부분 */
	testl	%eax, %eax /* 정렬되었으면 eax는 0이 된다. */
	jnz	bad_address	   /* PMD단위로 정렬이 안됐으면 bad_address */

	/* Is the address too large? */
	leaq	_text(%rip), %rdx
	movq	$PGDIR_SIZE, %rax /* 39bits? PGD 한개의 크기 (512G) */
	cmpq	%rax, %rdx /* PGD 한개로 커버되지 않으면 bad_address */
	jae	bad_address

	/* Fixup the physical addresses in the page table
	 */
	/* 세팅해놓은 페이지들에 커널이 실행중인 위치와의 갭을 더한다. */
	addq	%rbp, init_level4_pgt + 0(%rip)
	addq	%rbp, init_level4_pgt + (L4_PAGE_OFFSET*8)(%rip)
	/* ffff880000000000 - ffffc7ffffffffff (=64 TB) direct mapping of all phys.
	 * memory 의 L4 주소에 시작주소(LMA)를 더한다 */
	addq	%rbp, init_level4_pgt + (L4_START_KERNEL*8)(%rip)
	/* ffffffffa0000000 - fffffffffff00000 (=1536 MB) module mapping space
	 * 공간의 L4를 주소에 구해 시작주소를 더한다.
	 * 아래 사용할 영역들에 base주소를 모두 더한다. */
	addq	%rbp, level3_ident_pgt + 0(%rip)

	addq	%rbp, level3_kernel_pgt + (510*8)(%rip)
	addq	%rbp, level3_kernel_pgt + (511*8)(%rip)

	addq	%rbp, level2_fixmap_pgt + (506*8)(%rip)

	/* Add an Identity mapping if I am above 1G */
	/* PMD 한 페이지를 꽉 채우면 1G라 이걸 넘어서면 새 PUD가 필요하다. */
	/* 로드된 위치가 1G를 넘는지 체크해서 넘으면 새로 생성 */
	leaq	_text(%rip), %rdi
	andq	$PMD_PAGE_MASK, %rdi /* PMD이상(PMD,PUD,PGD)만 남는다. */

	movq	%rdi, %rax
	shrq	$PUD_SHIFT, %rax
	andq	$(PTRS_PER_PUD - 1), %rax /* PUD 만 구한다. */
	jz	ident_complete /* PUD가 0이면 패스 */

	leaq	(level2_spare_pgt - __START_KERNEL_map + _KERNPG_TABLE)(%rbp), %rdx
	leaq	level3_ident_pgt(%rip), %rbx
	movq	%rdx, 0(%rbx, %rax, 8) /* PUD 생성 */
		
	movq	%rdi, %rax
	shrq	$PMD_SHIFT, %rax
	andq	$(PTRS_PER_PMD - 1), %rax
	leaq	__PAGE_KERNEL_IDENT_LARGE_EXEC(%rdi), %rdx
	leaq	level2_spare_pgt(%rip), %rbx
	movq	%rdx, 0(%rbx, %rax, 8) /* mov [rbx+rax*8+0],rdx ; 1G넘는 영역 PMD 생성 */
ident_complete:

	/*
	 * Fixup the kernel text+data virtual addresses. Note that
	 * we might write invalid pmds, when the kernel is relocated
	 * cleanup_highmap() fixes this up along with the mappings
	 * beyond _end.
	 */

	leaq	level2_kernel_pgt(%rip), %rdi
 	leaq	4096(%rdi), %r8
	/* See if it is a valid page table entry */
	/* Present 비트를 체크한다. (페이지가 있는지 채크) */
1:	testq	$1, 0(%rdi)
	jz	2f
	addq	%rbp, 0(%rdi)
	/* Go to the next page */
2:	addq	$8, %rdi
	cmp	%r8, %rdi
	jne	1b

	/* Fixup phys_base */
	addq	%rbp, phys_base(%rip)

	/* Due to ENTRY(), sometimes the empty space gets filled with
	 * zeros. Better take a jmp than relying on empty space being
	 * filled with 0x90 (nop)
	 */
	/* ENTRY로 정렬된 곳으로 점프 */
	jmp secondary_startup_64

	/* BSP와 trampoline를 통한 AP들이 이쪽으로 점프한다. */
ENTRY(secondary_startup_64)
	/*
	 * At this point the CPU runs in 64bit mode CS.L = 1 CS.D = 1,
	 * and someone has loaded a mapped page table.
	 *
	 * %esi holds a physical pointer to real_mode_data.
	 *
	 * We come here either from startup_64 (using physical addresses)
	 * or from trampoline.S (using virtual addresses).
	 *
	 * Using virtual addresses from trampoline.S removes the need
	 * to have any identity mapped pages in the kernel page table
	 * after the boot processor executes this code.
	 */
	/* trampoline에서 들어오면 다른 코어들이 사용하도록
	 * PAE등과 페이징을 다시 초기화 해주는것 같다.
	 */
	/* Enable PAE mode and PGE */
	movl	$(X86_CR4_PAE | X86_CR4_PGE), %eax /* PAE와 PGE를 켠다. */
	movq	%rax, %cr4

	/* Setup early boot stage 4 level pagetables. */
	movq	$(init_level4_pgt - __START_KERNEL_map), %rax
	addq	phys_base(%rip), %rax
	movq	%rax, %cr3

	/* Ensure I am executing from virtual addresses */
	/* 0-512M의 물리메모리와 매핑시킨 VMA(0xffffffff80000000)로 점프 */
	movq	$1f, %rax
	jmp	*%rax
1:

	/* Check if nx is implemented */
	movl	$0x80000001, %eax
	cpuid
	movl	%edx,%edi

	/* Setup EFER (Extended Feature Enable Register) */
	movl	$MSR_EFER, %ecx
	rdmsr
	/* SYSCALL/SYSRET를 켠다. */
	btsl	$_EFER_SCE, %eax	/* Enable System Call */
	btl	$20,%edi		/* No Execute supported? */
	jnc     1f
	btsl	$_EFER_NX, %eax		/* 데이터 영역에서 실행하려 하면 page fault 예외가 발생한다. */
1:	wrmsr				/* Make changes effective */

	/* Setup cr0 */
#define CR0_STATE	(X86_CR0_PE | X86_CR0_MP | X86_CR0_ET | \
			 X86_CR0_NE | X86_CR0_WP | X86_CR0_AM | \
			 X86_CR0_PG)
	/* CR0 재설정 */
	movl	$CR0_STATE, %eax
	/* Make changes effective */
	movq	%rax, %cr0

	/* Setup a boot time stack */
	/* 스택 재설정 */
	movq stack_start(%rip),%rsp

	/* zero EFLAGS after setting rsp */
	pushq $0
	/* 스택(rsp)설정후 eflags 리셋 */
	popfq

	/*
	 * We must switch to a new descriptor in kernel space for the GDT
	 * because soon the kernel won't have access anymore to the userspace
	 * addresses where we're currently running on. We have to do that here
	 * because in 32bit we couldn't load a 64bit linear address.
	 */
	/* 일단 gdt 설정 */
	lgdt	early_gdt_descr(%rip)

	/* set up data segments */
	xorl %eax,%eax
	movl %eax,%ds
	movl %eax,%ss
	movl %eax,%es

	/*
	 * We don't really need to load %fs or %gs, but load them anyway
	 * to kill any stale realmode selectors.  This allows execution
	 * under VT hardware.
	 */
	movl %eax,%fs
	movl %eax,%gs

	/* Set up %gs.
	 *
	 * The base of %gs always points to the bottom of the irqstack
	 * union.  If the stack protector canary is enabled, it is
	 * located at %gs:40.  Note that, on SMP, the boot cpu uses
	 * init data section till per cpu areas are set up.
	 */
	/* #define MSR_GS_BASE	0xc0000101 : 64bit GS base */
	movl	$MSR_GS_BASE,%ecx
	movl	initial_gs(%rip),%eax
	movl	initial_gs+4(%rip),%edx
	wrmsr	

	/* esi is pointer to real mode structure with interesting info.
	   pass it to C */
	/* 리얼모드에서 얻은 boot 파라미터 포인터를 첫번째 인자로 전달 */
	movl	%esi, %edi
	
	/* Finally jump to run C code and to be on real kernel address
	 * Since we are running on identity-mapped space we have to jump
	 * to the full 64bit address, this is only possible as indirect
	 * jump.  In addition we need to ensure %cs is set so we make this
	 * a far return.
	 */
	/* 바로 아래 있는 x86_64_start_kernel의 코드로 넘어간다. */
	movq	initial_code(%rip),%rax
	pushq	$0		# fake return address to stop unwinder
	pushq	$__KERNEL_CS	# set correct cs
	/* x86_64_start_kernel 주소 */
	pushq	%rax		# target address in negative space
	lretq

	/* SMP bootup changes these two */
	__REFDATA
	.align	8
	ENTRY(initial_code)
	.quad	x86_64_start_kernel
	ENTRY(initial_gs)
	.quad	INIT_PER_CPU_VAR(irq_stack_union)

	/*
	 * 스택은 .ref.data 섹션을 가리키고 있다.
	 * 기본 thread_info와 task_struct가 이곳에 설정되어 있다.
	 */
	ENTRY(stack_start)
	.quad  init_thread_union+THREAD_SIZE-8
	.word  0
	__FINITDATA

bad_address:
	jmp bad_address

	.section ".init.text","ax"
	.globl early_idt_handlers
early_idt_handlers:
	# 104(%rsp) %rflags
	#  96(%rsp) %cs
	#  88(%rsp) %rip
	#  80(%rsp) error code
	i = 0
	.rept NUM_EXCEPTION_VECTORS
	.if (EXCEPTION_ERRCODE_MASK >> i) & 1
	ASM_NOP2
	.else
	pushq $0		# Dummy error code, to make stack frame uniform
	.endif
	pushq $i		# 72(%rsp) Vector number
	jmp early_idt_handler
	i = i + 1
	.endr

ENTRY(early_idt_handler)
	cld

	cmpl $2,early_recursion_flag(%rip)
	jz  1f
	incl early_recursion_flag(%rip)

	pushq %rax		# 64(%rsp)
	pushq %rcx		# 56(%rsp)
	pushq %rdx		# 48(%rsp)
	pushq %rsi		# 40(%rsp)
	pushq %rdi		# 32(%rsp)
	pushq %r8		# 24(%rsp)
	pushq %r9		# 16(%rsp)
	pushq %r10		#  8(%rsp)
	pushq %r11		#  0(%rsp)

	cmpl $__KERNEL_CS,96(%rsp)
	jne 10f

	leaq 88(%rsp),%rdi	# Pointer to %rip
	call early_fixup_exception
	andl %eax,%eax
	jnz 20f			# Found an exception entry

10:
#ifdef CONFIG_EARLY_PRINTK
	GET_CR2_INTO(%r9)	# can clobber any volatile register if pv
	movl 80(%rsp),%r8d	# error code
	movl 72(%rsp),%esi	# vector number
	movl 96(%rsp),%edx	# %cs
	movq 88(%rsp),%rcx	# %rip
	xorl %eax,%eax
	leaq early_idt_msg(%rip),%rdi
	call early_printk
	cmpl $2,early_recursion_flag(%rip)
	jz  1f
	call dump_stack
#ifdef CONFIG_KALLSYMS	
	leaq early_idt_ripmsg(%rip),%rdi
	movq 40(%rsp),%rsi	# %rip again
	call __print_symbol
#endif
#endif /* EARLY_PRINTK */
1:	hlt
	jmp 1b

20:	# Exception table entry found
	popq %r11
	popq %r10
	popq %r9
	popq %r8
	popq %rdi
	popq %rsi
	popq %rdx
	popq %rcx
	popq %rax
	addq $16,%rsp		# drop vector number and error code
	decl early_recursion_flag(%rip)
	INTERRUPT_RETURN

	.balign 4
early_recursion_flag:
	.long 0

#ifdef CONFIG_EARLY_PRINTK
early_idt_msg:
	.asciz "PANIC: early exception %02lx rip %lx:%lx error %lx cr2 %lx\n"
early_idt_ripmsg:
	.asciz "RIP %s\n"
#endif /* CONFIG_EARLY_PRINTK */
	.previous
/* page size로 정렬하고 심볼 선언 */
#define NEXT_PAGE(name) \
	.balign	PAGE_SIZE; \
ENTRY(name)

/* Automate the creation of 1 to 1 mapping pmd entries */
#define PMDS(START, PERM, COUNT)			\
	i = 0 ;						\
	.rept (COUNT) ;					\
	.quad	(START) + (i << PMD_SHIFT) + (PERM) ;	\
	i = i + 1 ;					\
	.endr

	.data
	/*
	 * This default setting generates an ident mapping at address 0x100000
	 * and a mapping for the kernel that precisely maps virtual address
	 * 0xffffffff80000000 to physical address 0x000000. (always using
	 * 2Mbyte large pages provided by PAE mode)
	 */
/*
 * 커널영역 0xffffffff80000000은 물리메모리 0번지를 매핑
 * 페이지 테이블 크기로 정렬후 심볼 지정(NEXT_PAGE)
 * 내부는 다음 레벨의 페이지 테이블 내용을 담고 있다.
 *
 * linux-x86-8/Documentation/x86/x86_64/mm.txt 참조
 * init_level4_pgt는 direct mapping된 가상주소공간이다.
 * 때문에 페이지 엔트리에서 물리주소를 쓸때는 0xfff...8000을 빼준다.
 * C 포인터에 init_level... 심볼을 대입하면 바로 접근이 가능하다.
 * 오프셋에 __START_KERNEL_map을 빼주는 이유는 오프셋이 VMA로 계산되기 때문인것 같다.
 */
NEXT_PAGE(init_level4_pgt)
	/* level3_ident_pgt의 상대주소 */
	.quad	level3_ident_pgt - __START_KERNEL_map + _KERNPG_TABLE
	.org	init_level4_pgt + L4_PAGE_OFFSET*8, 0 /* 0xffff8800.. 의 LV4 인덱스 */
	.quad	level3_ident_pgt - __START_KERNEL_map + _KERNPG_TABLE
	.org	init_level4_pgt + L4_START_KERNEL*8, 0 /* 0xffffffff800..(커널) 영역의 LV4 인덱스 */
	/* (2^48-(2*1024*1024*1024))/(2^39) = 511 */
	.quad	level3_kernel_pgt - __START_KERNEL_map + _PAGE_TABLE 

NEXT_PAGE(level3_ident_pgt)
	.quad	level2_ident_pgt - __START_KERNEL_map + _KERNPG_TABLE /* 1G 영역만 다이렉트 매핑한다. 한개의 PUD는 1G (30bits) */
	.fill	511,8,0 /* 위쪽 quad까지 합쳐서 512 * 8 = 4k */

NEXT_PAGE(level3_kernel_pgt)
	.fill	L3_START_KERNEL,8,0 /* 커널을 매핑할 0xffffffff80000000의 위치를 구한다. */
	/* (2^48-(2*1024*1024*1024)-((2^39)*511))/(2^30) = 510 */
	.quad	level2_kernel_pgt - __START_KERNEL_map + _KERNPG_TABLE /* P, RW, ACCESS, DIRTY ; 512M 커널 영역 */
	.quad	level2_fixmap_pgt - __START_KERNEL_map + _PAGE_TABLE   /* P, RW, USER, ACCESS, DIRTY ; 모듈 영역? */

NEXT_PAGE(level2_fixmap_pgt)
	.fill	506,8,0
	.quad	level1_fixmap_pgt - __START_KERNEL_map + _PAGE_TABLE
	/* 8MB reserved for vsyscalls + a 2MB hole = 4 + 1 entries */
	.fill	5,8,0

NEXT_PAGE(level1_fixmap_pgt)
	.fill	512,8,0

NEXT_PAGE(level2_ident_pgt)	  /* PMD를 꽉채우면 1G이다. 물리메모리와 1:1 매핑한다. */
	/* Since I easily can, map the first 1G.
	 * Don't set NX because code runs from these pages.
	 */
	PMDS(0, __PAGE_KERNEL_IDENT_LARGE_EXEC, PTRS_PER_PMD) /* 0부터 PMD크기만큼 채운다. 플래그는 __PAGE_KERNEL_IDENT_LARGE_EXEC (RW,P,DIRTY,PSE등이 켜있다.고로 이 페이지는 2M크기) */

NEXT_PAGE(level2_kernel_pgt)	/* 커널의 512M 매핑영역 */
	/*
	 * 512 MB kernel mapping. We spend a full page on this pagetable
	 * anyway.
	 *
	 * The kernel code+data+bss must not be bigger than that.
	 *
	 * (NOTE: at +512MB starts the module area, see MODULES_VADDR.
	 *  If you want to increase this then increase MODULES_VADDR
	 *  too.)
	 */
	/* LARGE가 붙은건 2M 페이징이다. KERNEL_IMAGE_SIZE는 512M / 2M (PMD크기) = 256개. 0xffffffff80000000영역은 물리메모리 0부터 512M만 매핑하면 된다. */
	PMDS(0, __PAGE_KERNEL_LARGE_EXEC,
		KERNEL_IMAGE_SIZE/PMD_SIZE)

NEXT_PAGE(level2_spare_pgt)
	.fill   512, 8, 0

#undef PMDS
#undef NEXT_PAGE

	.data
	.align 16
	.globl early_gdt_descr
early_gdt_descr:
	.word	GDT_ENTRIES*8-1
early_gdt_descr_base:
	.quad	INIT_PER_CPU_VAR(gdt_page)

ENTRY(phys_base)
	/* This must match the first entry in level2_kernel_pgt */
	.quad   0x0000000000000000

#include "../../x86/xen/xen-head.S"
	
	.section .bss, "aw", @nobits
	.align L1_CACHE_BYTES
ENTRY(idt_table)
	.skip IDT_ENTRIES * 16

	.align L1_CACHE_BYTES
ENTRY(nmi_idt_table)
	.skip IDT_ENTRIES * 16

	__PAGE_ALIGNED_BSS
	.align PAGE_SIZE
ENTRY(empty_zero_page)
	.skip PAGE_SIZE
