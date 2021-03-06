/* Copyright (C) 2003-2014 Free Software Foundation, Inc.
   This file is part of the GNU C Library.

   The GNU C Library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   The GNU C Library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with the GNU C Library; if not, see
   <http://www.gnu.org/licenses/>.  */

#include <sysdep.h>
#include <shlib-compat.h>
#include <lowlevellock.h>
#include <lowlevelcond.h>
#include <kernel-features.h>
#include <pthread-errnos.h>
#include "lowlevel-atomic.h"

	.text

	/* int pthread_cond_signal (pthread_cond_t *cond) */
	.globl	__pthread_cond_signal
	.type	__pthread_cond_signal, @function
	.align	5
	cfi_startproc
__pthread_cond_signal:
	mov.l	r8, @-r15
	cfi_adjust_cfa_offset (4)
	cfi_rel_offset (r8, 0)
	sts.l	pr, @-r15
	cfi_adjust_cfa_offset (4)
	cfi_rel_offset (pr, 0)
	mov	r4, r8

	/* Get internal lock.  */
	mov	#0, r3
	mov	#1, r4
#if cond_lock != 0
	CMPXCHG (r3, @(cond_lock,r8), r4, r2)
#else
	CMPXCHG (r3, @r8, r4, r2)
#endif
	bf	1f
2:
	mov.l	@(total_seq+4,r8),r0
	mov.l	@(total_seq,r8),r1
	mov.l	@(wakeup_seq+4,r8), r2
	cmp/hi	r2, r0
	bt	3f
	cmp/hi	r0, r2
	bt	4f
	mov.l	@(wakeup_seq,r8), r2
	cmp/hi	r2, r1
	bf	4f

3:
	/* Bump the wakeup number.  */
	mov	#1, r2
	mov	#0, r3
	clrt
	mov.l	@(wakeup_seq,r8),r0
	mov.l	@(wakeup_seq+4,r8),r1
	addc	r2, r0
	addc	r3, r1
	mov.l	r0,@(wakeup_seq,r8)
	mov.l	r1,@(wakeup_seq+4,r8)
	mov.l	@(cond_futex,r8),r0
	add	r2, r0
	mov.l	r0,@(cond_futex,r8)

	/* Wake up one thread.  */
	mov	r8, r4
	add	#cond_futex, r4
	mov.l	@(dep_mutex,r8), r0
	cmp/eq	#-1, r0
	bt/s	99f
	 mov	#FUTEX_WAKE_OP, r5
#ifdef __ASSUME_PRIVATE_FUTEX
	mov	#(FUTEX_WAKE_OP|FUTEX_PRIVATE_FLAG), r5
	extu.b	r5, r5
#else
	stc	gbr, r1
	mov.w	.Lpfoff, r2
	add	r2, r1
	mov.l	@r1, r5
	mov	#FUTEX_WAKE_OP, r0
	or	r0, r5
#endif
99:
	mov	#1, r6
	mov	#0, r7
	mov	r8, r0
	add	#cond_lock, r0
	mov.l	.Lfutexop, r1
	mov	#SYS_futex, r3
	extu.b	r3, r3
	trapa	#0x14
	SYSCALL_INST_PAD

	/* For any kind of error, we try again with WAKE.
	   The general test also covers running on old kernels.  */
	mov	r0, r1
	mov	#-12, r2
	shad	r2, r1
	not	r1, r1
	tst	r1, r1
	bt	7f

6:
	cfi_remember_state
	lds.l	@r15+, pr
	cfi_adjust_cfa_offset (-4)
	cfi_restore (pr)
	mov.l	@r15+, r8
	cfi_adjust_cfa_offset (-4)
	cfi_restore (r8)
	rts
	 mov	#0, r0
	cfi_restore_state

#ifndef __ASSUME_PRIVATE_FUTEX
.Lpfoff:
	.word	PRIVATE_FUTEX - TLS_PRE_TCB_SIZE
#endif
	.align	2
.Lfutexop:
	.long	FUTEX_OP_CLEAR_WAKE_IF_GT_ONE

7:
	/* r5 should be either FUTEX_WAKE_OP or
	   FUTEX_WAKE_OP|FUTEX_PRIVATE_FLAG from the previous syscall.  */
	mov	#(FUTEX_WAKE ^ FUTEX_WAKE_OP), r0
	xor	r0, r5
	trapa	#0x14
	SYSCALL_INST_PAD

4:
	/* Unlock.  */
#if cond_lock != 0
	DEC (@(cond_lock,r8), r2)
#else
	DEC (@r8, r2)
#endif
	tst	r2, r2
	bt	6b

5:
	/* Unlock in loop requires wakeup.  */
	mov	r8, r4
#if cond_lock != 0
	add	#cond_lock, r4
#endif
	mov.l	@(dep_mutex,r8), r0
	cmp/eq	#-1, r0
	bf/s	99f
	 mov	#LLL_PRIVATE, r5
	mov	#LLL_SHARED, r5
99:
	mov.l	.Lwake4, r1
	bsrf	r1
	 extu.b	r5, r5
.Lwake4b:
	bra	6b
	 nop

1:
	/* Initial locking failed.  */
	mov	r8, r5
#if cond_lock != 0
	add	#cond_lock, r5
#endif
	mov.l	@(dep_mutex,r8), r0
	cmp/eq	#-1, r0
	bf/s	99f
	 mov	#LLL_PRIVATE, r6
	mov	#LLL_SHARED, r6
99:
	extu.b	r6, r6
	mov.l	.Lwait4, r1
	bsrf	r1
	 mov	r2, r4
.Lwait4b:
	bra	2b
	 nop
	cfi_endproc

	.align	2
.Lwait4:
	.long	__lll_lock_wait-.Lwait4b
.Lwake4:
	.long	__lll_unlock_wake-.Lwake4b
	.size	__pthread_cond_signal, .-__pthread_cond_signal
versioned_symbol (libpthread, __pthread_cond_signal, pthread_cond_signal,
		  GLIBC_2_3_2)

