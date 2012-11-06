#ifndef _LINUX_STDDEF_H
#define _LINUX_STDDEF_H

#include <uapi/linux/stddef.h>


#undef NULL
#define NULL ((void *)0)

enum {
	false	= 0,
	true	= 1
};

#undef offsetof
#ifdef __compiler_offsetof
#define offsetof(TYPE,MEMBER) __compiler_offsetof(TYPE,MEMBER)
#else
/* 구조체의 시작을 0으로 시작하는 멤버의 번지값을 얻는다. */
#define offsetof(TYPE, MEMBER) ((size_t) &((TYPE *)0)->MEMBER)
#endif
#endif
