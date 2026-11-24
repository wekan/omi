/* Omi on AmigaOS 3: what SQLite needs and libnix does not have. */
#include <errno.h>
#include <sys/types.h>
#include <sys/mman.h>

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
    (void)addr; (void)len; (void)prot; (void)flags; (void)fd; (void)off;
    errno = ENOSYS;
    return MAP_FAILED;
}

int munmap(void *addr, size_t len)
{
    (void)addr; (void)len;
    errno = ENOSYS;
    return -1;
}
