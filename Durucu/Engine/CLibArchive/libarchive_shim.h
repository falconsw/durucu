// macOS ships libarchive (/usr/lib/libarchive.2.dylib) and its .tbd in the SDK,
// but not the headers. These declarations mirror the stable public ABI of
// libarchive 3.x for the subset Dürücü uses.

#ifndef DURUCU_LIBARCHIVE_SHIM_H
#define DURUCU_LIBARCHIVE_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF      1
#define ARCHIVE_OK       0
#define ARCHIVE_RETRY  (-10)
#define ARCHIVE_WARN   (-20)
#define ARCHIVE_FAILED (-25)
#define ARCHIVE_FATAL  (-30)

#define AE_IFMT   0170000
#define AE_IFREG  0100000
#define AE_IFLNK  0120000
#define AE_IFDIR  0040000

#define ARCHIVE_EXTRACT_PERM                 0x0002
#define ARCHIVE_EXTRACT_TIME                 0x0004
#define ARCHIVE_EXTRACT_NO_OVERWRITE         0x0008
#define ARCHIVE_EXTRACT_UNLINK               0x0010
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS      0x0100
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT      0x0200

// MARK: Generic

const char *archive_error_string(struct archive *);
int archive_errno(struct archive *);
const char *archive_format_name(struct archive *);
int archive_filter_count(struct archive *);
const char *archive_filter_name(struct archive *, int);
int64_t archive_filter_bytes(struct archive *, int);

// MARK: Reading

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_set_options(struct archive *, const char *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_block(struct archive *, const void **, size_t *, int64_t *);
int archive_read_data_skip(struct archive *);
int archive_read_has_encrypted_entries(struct archive *);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);

// MARK: Writing

struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_format_7zip(struct archive *);
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_add_filter_gzip(struct archive *);
int archive_write_add_filter_xz(struct archive *);
int archive_write_add_filter_bzip2(struct archive *);
int archive_write_set_options(struct archive *, const char *);
int archive_write_set_passphrase(struct archive *, const char *);
int archive_write_set_bytes_in_last_block(struct archive *, int);
int archive_write_open_filename(struct archive *, const char *);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
ssize_t archive_write_data_block(struct archive *, const void *, size_t, int64_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int);
int archive_write_disk_set_standard_lookup(struct archive *);

// MARK: Entries

struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
long archive_entry_mtime_nsec(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

void archive_entry_copy_pathname(struct archive_entry *, const char *);
void archive_entry_copy_hardlink(struct archive_entry *, const char *);
void archive_entry_copy_symlink(struct archive_entry *, const char *);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, mode_t);
void archive_entry_set_mtime(struct archive_entry *, time_t, long);

#endif
