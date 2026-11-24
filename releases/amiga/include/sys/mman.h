/* Omi on AmigaOS 3: there is no mmap. SQLite is built with WAL (Gitea's
   database is a WAL database) and SQLITE_DEFAULT_LOCKING_MODE=1: in
   EXCLUSIVE locking mode SQLite keeps WAL's index in its own memory and never
   calls these, which omi_amiga.c defines only so that it links. */
#ifndef OMI_AMIGA_SYS_MMAN_H
#define OMI_AMIGA_SYS_MMAN_H
#include <sys/types.h>
#define PROT_NONE 0
#define PROT_READ 1
#define PROT_WRITE 2
#define MAP_SHARED 1
#define MAP_PRIVATE 2
#define MAP_FAILED ((void *)-1)
void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
int munmap(void *addr, size_t len);
#endif
