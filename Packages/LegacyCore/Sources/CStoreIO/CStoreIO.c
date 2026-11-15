#include "CStoreIO.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

int fl_errno(void) { return errno; }
void fl_close(int fd) { if (fd >= 0) close(fd); }
int fl_open_directory(const char *path) {
    return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}
int fl_open_file(int directory, const char *name, int writable) {
    return openat(directory, name, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC);
}
int fl_identity(int fd, FLFileIdentity *out) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
    if (!S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size < 0) { errno = EINVAL; return -1; }
    out->device = st.st_dev; out->inode = st.st_ino; out->size = st.st_size;
#if __APPLE__
    out->modified_seconds = st.st_mtimespec.tv_sec; out->modified_nanoseconds = st.st_mtimespec.tv_nsec;
#else
    out->modified_seconds = st.st_mtim.tv_sec; out->modified_nanoseconds = st.st_mtim.tv_nsec;
#endif
    return 0;
}
int fl_path_matches(int directory, const char *name, const FLFileIdentity *expected) {
    struct stat st;
    if (fstatat(directory, name, &st, AT_SYMLINK_NOFOLLOW) != 0) return 0;
    return S_ISREG(st.st_mode) && st.st_nlink == 1 && (uint64_t)st.st_dev == expected->device
        && (uint64_t)st.st_ino == expected->inode && (uint64_t)st.st_size == expected->size;
}
int fl_lock_file(int fd, int exclusive) { return flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB); }
int fl_read_file(int fd, void *buffer, size_t size) {
    size_t done = 0;
    while (done < size) {
        ssize_t n = pread(fd, (char *)buffer + done, size - done, (off_t)done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return -1; }
        done += (size_t)n;
    }
    return 0;
}
int fl_write_bytes(int fd, const void *buffer, size_t size, uint64_t offset) {
    size_t done = 0;
    while (done < size) {
        ssize_t n = pwrite(fd, (const char *)buffer + done, size - done, (off_t)(offset + done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return -1; }
        done += (size_t)n;
    }
    return 0;
}
int fl_sync(int fd) { return fsync(fd); }
int fl_sync_path(const char *path, int directory) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0));
    if (fd < 0) return -1;
    int result = fsync(fd); int saved = errno; close(fd); errno = saved; return result;
}
