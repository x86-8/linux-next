#ifndef _ASM_X86_SPINLOCK_H
#define _ASM_X86_SPINLOCK_H

#include <linux/atomic.h>
#include <asm/page.h>
#include <asm/processor.h>
#include <linux/compiler.h>
#include <asm/paravirt.h>
/*
 * Your basic SMP spinlocks, allowing only a single CPU anywhere
 *
 * Simple spin lock operations.  There are two variants, one clears IRQ's
 * on the local processor, one does not.
 *
 * These are fair FIFO ticket locks, which support up to 2^16 CPUs.
 *
 * (the type definitions are in asm/spinlock_types.h)
 */

#ifdef CONFIG_X86_32
# define LOCK_PTR_REG "a"
#else
# define LOCK_PTR_REG "D"
#endif

#if defined(CONFIG_X86_32) && \
	(defined(CONFIG_X86_OOSTORE) || defined(CONFIG_X86_PPRO_FENCE))
/*
 * On PPro SMP or if we are using OOSTORE, we use a locked operation to unlock
 * (PPro errata 66, 92)
 */
# define UNLOCK_LOCK_PREFIX LOCK_PREFIX
#else
# define UNLOCK_LOCK_PREFIX
#endif

/*
 * Ticket locks are conceptually two parts, one indicating the current head of
 * the queue, and the other indicating the current tail. The lock is acquired
 * by atomically noting the tail and incrementing it by one (thus adding
 * ourself to the queue and noting our position), then waiting until the head
 * becomes equal to the the initial value of the tail.
 *
 * We use an xadd covering *both* parts of the lock, to increment the tail and
 * also load the position of the head, which takes care of memory ordering
 * issues and should be optimal for the uncontended case. Note the tail must be
 * in the high part, because a wide xadd increment of the low part would carry
 * up and contaminate the high part.
 * http://studyfoss.egloos.com/5144295
 */
static __always_inline void __ticket_spin_lock(arch_spinlock_t *lock)
{
	register struct __raw_tickets inc = { .tail = 1 };
	/* inc = 원래값= lock->tickets
	 * lock->tickets += inc
	 * 이번 티켓을 발급한다. (head)
	 */
	inc = xadd(&lock->tickets, inc);
	for (;;) {		
		/* 글자가 짧아서 while보다 for를 선호, VC에서는 warning?
		 * while파와 for 파가 전쟁중
		 */
		if (inc.head == inc.tail)
			/* 자신의 티켓과(tail) 현재 순서를(head) 비교한다. 락을 얻었으면 break */
			break;
/* Pentium4 이상에서는 rep nop는 pause 명령으로 동작하고
 * 이전 프로세서에서는 단순한 nop로 동작한다.
 * pause는 스핀락에서 cpu에 힌트를 제공해 성능을 증가시키고 전력소모를 줄인다. */
		cpu_relax();
		/* 자기 순서라면 head가 같은 값으로 갱신된다 */
		inc.head = ACCESS_ONCE(lock->tickets.head);
	/* 자신의 티켓 순서를 기다리며 spin */
	}
	/* 컴파일러가 memory reordering을 못하게 메모리 장벽을 친다. */
	barrier();		/* make sure nothing creeps before the lock is taken */
}

static __always_inline int __ticket_spin_trylock(arch_spinlock_t *lock)
{
	arch_spinlock_t old, new;

	old.tickets = ACCESS_ONCE(lock->tickets);
	if (old.tickets.head != old.tickets.tail)
		return 0;

	new.head_tail = old.head_tail + (1 << TICKET_SHIFT);

	/* cmpxchg is a full barrier, so nothing can move before it */
	return cmpxchg(&lock->head_tail, old.head_tail, new.head_tail) == old.head_tail;
}

static __always_inline void __ticket_spin_unlock(arch_spinlock_t *lock)
{
  /* head를 증가시킨다. (unlock), 이전(3.2)에서는 inline asm이
   * 있었는데, 3.7에서는 (inline asm) 매크로로 다시 한번 감쌌음. */
	__add(&lock->tickets.head, 1, UNLOCK_LOCK_PREFIX);
}

static inline int __ticket_spin_is_locked(arch_spinlock_t *lock)
{
	struct __raw_tickets tmp = ACCESS_ONCE(lock->tickets);

	return tmp.tail != tmp.head;
}

static inline int __ticket_spin_is_contended(arch_spinlock_t *lock)
{
	struct __raw_tickets tmp = ACCESS_ONCE(lock->tickets);

	return (__ticket_t)(tmp.tail - tmp.head) > 1;
}

#ifndef CONFIG_PARAVIRT_SPINLOCKS

static inline int arch_spin_is_locked(arch_spinlock_t *lock)
{
	return __ticket_spin_is_locked(lock);
}

static inline int arch_spin_is_contended(arch_spinlock_t *lock)
{
	return __ticket_spin_is_contended(lock);
}
#define arch_spin_is_contended	arch_spin_is_contended

static __always_inline void arch_spin_lock(arch_spinlock_t *lock)
{
	__ticket_spin_lock(lock);
}

static __always_inline int arch_spin_trylock(arch_spinlock_t *lock)
{
	return __ticket_spin_trylock(lock);
}

static __always_inline void arch_spin_unlock(arch_spinlock_t *lock)
{
	__ticket_spin_unlock(lock);
}

static __always_inline void arch_spin_lock_flags(arch_spinlock_t *lock,
						  unsigned long flags)
{
	arch_spin_lock(lock);
}

#endif	/* CONFIG_PARAVIRT_SPINLOCKS */

static inline void arch_spin_unlock_wait(arch_spinlock_t *lock)
{
	while (arch_spin_is_locked(lock))
		cpu_relax();
}

/*
 * Read-write spinlocks, allowing multiple readers
 * but only one writer.
 *
 * NOTE! it is quite common to have readers in interrupts
 * but no interrupt writers. For those circumstances we
 * can "mix" irq-safe locks - any writer needs to get a
 * irq-safe write-lock, but readers can get non-irqsafe
 * read-locks.
 *
 * On x86, we implement read-write locks as a 32-bit counter
 * with the high bit (sign) being the "contended" bit.
 */

/**
 * read_can_lock - would read_trylock() succeed?
 * @lock: the rwlock in question.
 */
static inline int arch_read_can_lock(arch_rwlock_t *lock)
{
	return lock->lock > 0;
}

/**
 * write_can_lock - would write_trylock() succeed?
 * @lock: the rwlock in question.
 */
static inline int arch_write_can_lock(arch_rwlock_t *lock)
{
	return lock->write == WRITE_LOCK_CMP;
}
/* readers writers lock 모뎀로 cpu가 2048개 이하면
 * read lock(20비트)와 write lock(12비트) 를 32비트로 같이 사용한다.
 * 2048개를 초과하면 64비트를 반으로 나눠서 사용한다.
 * R-R는 부호 비트가 켜지지 않을 경우 (0xfffff~0) 계속 획득할수 있으며
 * W-R, W-W, R-W 로 락이 걸리면 상호 배제되며 끝날때까지 spin하며 대기한다.
 */
static inline void arch_read_lock(arch_rwlock_t *rw)
{
	/* 감소시켜 보고 획득 못하면 스핀도는 루틴을 호출 */
	asm volatile(LOCK_PREFIX READ_LOCK_SIZE(dec) " (%0)\n\t"
		     "jns 1f\n"
		     "call __read_lock_failed\n\t"
		     "1:\n"
		     ::LOCK_PTR_REG (rw) : "memory");
}

static inline void arch_write_lock(arch_rwlock_t *rw)
{
	/* lock 프리픽스로 다른명령어가 끼어들수 없게 한다.
	 * 두가지 경우가 있는데 dec면 그냥 1을 감소 (cpu수>2048)
	 * sub면 BIAS (0x100000==1M) 감소 (cpu<=2048)해서 0이면 락을 획득하였다.
	 */
	asm volatile(LOCK_PREFIX WRITE_LOCK_SUB(%1) "(%0)\n\t"
		     "jz 1f\n"
		     "call __write_lock_failed\n\t"
		     "1:\n"
		     ::LOCK_PTR_REG (&rw->write), "i" (RW_LOCK_BIAS)
		     : "memory");
}

static inline int arch_read_trylock(arch_rwlock_t *lock)
{
	READ_LOCK_ATOMIC(t) *count = (READ_LOCK_ATOMIC(t) *)lock;

	if (READ_LOCK_ATOMIC(dec_return)(count) >= 0)
		return 1;
	READ_LOCK_ATOMIC(inc)(count);
	return 0;
}

static inline int arch_write_trylock(arch_rwlock_t *lock)
{
	atomic_t *count = (atomic_t *)&lock->write;

	if (atomic_sub_and_test(WRITE_LOCK_CMP, count))
		return 1;
	atomic_add(WRITE_LOCK_CMP, count);
	return 0;
}

static inline void arch_read_unlock(arch_rwlock_t *rw)
{
	asm volatile(LOCK_PREFIX READ_LOCK_SIZE(inc) " %0"
		     :"+m" (rw->lock) : : "memory");
}
/* 쓰기는 상위 바이어스 값 혹은 하위 4바이트  */
static inline void arch_write_unlock(arch_rwlock_t *rw)
{
	asm volatile(LOCK_PREFIX WRITE_LOCK_ADD(%1) "%0"
		     : "+m" (rw->write) : "i" (RW_LOCK_BIAS) : "memory");
}

#define arch_read_lock_flags(lock, flags) arch_read_lock(lock)
#define arch_write_lock_flags(lock, flags) arch_write_lock(lock)

#undef READ_LOCK_SIZE
#undef READ_LOCK_ATOMIC
#undef WRITE_LOCK_ADD
#undef WRITE_LOCK_SUB
#undef WRITE_LOCK_CMP

#define arch_spin_relax(lock)	cpu_relax()
#define arch_read_relax(lock)	cpu_relax()
#define arch_write_relax(lock)	cpu_relax()

/* The {read|write|spin}_lock() on x86 are full memory barriers. */
static inline void smp_mb__after_lock(void) { }
#define ARCH_HAS_SMP_MB_AFTER_LOCK

#endif /* _ASM_X86_SPINLOCK_H */
