#ifndef FL_STORE_IO_H
#define FL_STORE_IO_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t device, inode, size;
    int64_t modified_seconds, modified_nanoseconds;
} FLFileIdentity;

int fl_open_directory(const char *path);
int fl_open_file(int directory, const char *name, int writable);
int fl_identity(int fd, FLFileIdentity *identity);
int fl_path_matches(int directory, const char *name, const FLFileIdentity *identity);
int fl_lock_file(int fd, int exclusive);
int fl_read_file(int fd, void *buffer, size_t size);
int fl_write_bytes(int fd, const void *buffer, size_t size, uint64_t offset);
int fl_sync(int fd);
int fl_sync_path(const char *path, int directory);
void fl_close(int fd);
int fl_errno(void);
#endif
