#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>
#include <usbmuxd.h>
#include <plist/plist.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "source-binding.h"

#define DB_LIMIT (256ULL * 1024ULL * 1024ULL)
#define WAL_LIMIT (64ULL * 1024ULL * 1024ULL)
#define CHUNK_SIZE 65536

static int info_values(char **info, uint64_t *bytes, char **mtime) {
    int regular = 0, has_size = 0, has_mtime = 0;
    for (int i = 0; info && info[i] && info[i + 1]; i += 2) {
        if (!strcmp(info[i], "st_ifmt")) regular = !strcmp(info[i + 1], "S_IFREG");
        if (!strcmp(info[i], "st_size")) {
            char *end = NULL; errno = 0;
            if (info[i + 1][0] >= '0' && info[i + 1][0] <= '9') {
                *bytes = strtoull(info[i + 1], &end, 10);
                has_size = errno == 0 && end && *end == '\0';
            }
        }
        if (!strcmp(info[i], "st_mtime")) { *mtime = info[i + 1]; has_mtime = 1; }
    }
    return regular && has_size && has_mtime;
}

static int copy_one(afc_client_t afc, int dirfd, const char *remote, const char *local,
                    uint64_t limit, int optional, uint64_t *copied, int *stable, int *present) {
    char **before_info = NULL, **after_info = NULL;
    uint64_t expected = 0, after_size = 0, handle = 0;
    char *before_mtime = NULL, *after_mtime = NULL;
    int out = -1, ok = 0;
    afc_error_t e = afc_get_file_info(afc, remote, &before_info);
    *copied = 0;
    *present = 0;
    if (e == AFC_E_OBJECT_NOT_FOUND && optional) return 1;
    if (e != AFC_E_SUCCESS || !info_values(before_info, &expected, &before_mtime) || expected > limit) goto done;
    *present = 1;
    out = openat(dirfd, local, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (out < 0) goto done;
    if (afc_file_open(afc, remote, AFC_FOPEN_RDONLY, &handle) != AFC_E_SUCCESS || !handle) goto done;
    uint64_t total = 0;
    char buffer[CHUNK_SIZE];
    while (total < expected) {
        uint32_t n = 0;
        uint32_t want = (uint32_t)((expected - total) < sizeof(buffer) ? expected - total : sizeof(buffer));
        if (afc_file_read(afc, handle, buffer, want, &n) != AFC_E_SUCCESS || n == 0 || n > want) goto done;
        size_t written = 0;
        while (written < n) {
            ssize_t w = write(out, buffer + written, n - written);
            if (w <= 0) goto done;
            written += (size_t)w;
        }
        total += n;
        *copied = total;
    }
    if (afc_file_close(afc, handle) != AFC_E_SUCCESS) { handle = 0; goto done; }
    handle = 0;
    if (afc_get_file_info(afc, remote, &after_info) != AFC_E_SUCCESS ||
        !info_values(after_info, &after_size, &after_mtime)) goto done;
    *stable = expected == after_size && strcmp(before_mtime, after_mtime) == 0;
    if (total != expected || fsync(out) != 0) goto done;
    ok = 1;
done:
    if (handle) afc_file_close(afc, handle);
    if (out >= 0) close(out);
    if (before_info) afc_dictionary_free(before_info);
    if (after_info) afc_dictionary_free(after_info);
    return ok;
}

static int write_source_binding(int dirfd, const char *udid) {
    uint8_t binding[SOURCE_BINDING_BYTES];
    if (!source_binding_create(udid, binding)) { memset(binding, 0, sizeof(binding)); return 0; }
    int fd = openat(dirfd, "source-binding.bin", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { memset(binding, 0, sizeof(binding)); return 0; }
    int ok = fchmod(fd, 0600) == 0;
    size_t total = 0;
    while (ok && total < sizeof(binding)) {
        ssize_t written = write(fd, binding + total, sizeof(binding) - total);
        if (written <= 0) ok = 0;
        else total += (size_t)written;
    }
    if (ok && fsync(fd) != 0) ok = 0;
    if (close(fd) != 0) ok = 0;
    memset(binding, 0, sizeof(binding));
    return ok;
}

// Run only under an external process deadline. No automatic pairing or writes.
int main(int argc, char **argv) {
    int copy_mode = 0, dirfd = -1;
    if (argc != 1 && !(argc == 3 && !strcmp(argv[1], "--copy-metadata"))) {
        fprintf(stderr, "usage: %s [--copy-metadata existing-new-folder]\n", argv[0]); return 2;
    }
    if (argc == 3) {
        struct stat st;
        dirfd = open(argv[2], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (dirfd < 0 || fstat(dirfd, &st) != 0 || !S_ISDIR(st.st_mode)) {
            if (dirfd >= 0) close(dirfd);
            printf("{\"source\":\"iphone_afc\",\"status\":\"local_folder_unavailable\",\"assetCounts\":null}\n"); return 1;
        }
        copy_mode = 1;
    }
    idevice_info_t *devices = NULL;
    int count = 0, usb_count = 0;
    const char *udid = NULL;
    idevice_t device = NULL;
    lockdownd_client_t lockdown = NULL;
    lockdownd_service_descriptor_t service = NULL;
    afc_client_t afc = NULL;
    char *record = NULL, *host_id = NULL, *buid = NULL, *session_id = NULL;
    uint32_t record_size = 0;
    plist_t pair = NULL;
    char **info = NULL;
    uint64_t file = 0, size = 0;
    int ssl = 0, valid_header = 0;
    uint64_t db_copied = 0, wal_copied = 0;
    int db_stable = 0, wal_stable = 0, wal_present = 0, db_present = 0;
    const char *status = "device_discovery_failed";
    const char *path = "/PhotoData/Photos.sqlite";

    unsetenv("USBMUXD_SOCKET_ADDRESS");
    idevice_set_debug_level(0);
    if (idevice_get_device_list_extended(&devices, &count) != IDEVICE_E_SUCCESS) goto cleanup;
    for (int i = 0; i < count; i++) {
        if (devices[i]->conn_type == CONNECTION_USBMUXD) {
            usb_count++;
            udid = devices[i]->udid;
        }
    }
    status = "requires_exactly_one_usb_device";
    if (usb_count != 1 || !udid) goto cleanup;
    status = "existing_pair_record_unavailable";
    if (usbmuxd_read_pair_record(udid, &record, &record_size) != 0 || !record || record_size == 0) goto cleanup;
    status = "invalid_pair_record";
    if (plist_from_memory(record, record_size, &pair, NULL) != PLIST_ERR_SUCCESS || !pair) goto cleanup;
    plist_t host = plist_dict_get_item(pair, "HostID");
    if (!host || plist_get_node_type(host) != PLIST_STRING) goto cleanup;
    plist_get_string_val(host, &host_id);
    if (!host_id || !host_id[0]) goto cleanup;
    status = "existing_system_buid_unavailable";
    if (usbmuxd_read_buid(&buid) != 0 || !buid || !buid[0]) goto cleanup;
    status = "usb_connection_failed";
    if (idevice_new_with_options(&device, udid, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) goto cleanup;
    status = "lockdown_connection_failed";
    if (lockdownd_client_new(device, &lockdown, "LocalPhotosSyncCatalogProbe") != LOCKDOWN_E_SUCCESS) goto cleanup;
    status = "existing_pair_session_failed";
    if (lockdownd_start_session(lockdown, host_id, &session_id, &ssl) != LOCKDOWN_E_SUCCESS || !session_id || !session_id[0]) goto cleanup;
    status = "afc_service_unavailable";
    if (lockdownd_start_service(lockdown, AFC_SERVICE_NAME, &service) != LOCKDOWN_E_SUCCESS || !service || service->port == 0) goto cleanup;
    // libimobiledevice 1.4.0 does not check AFC service TLS setup failure.
    status = "afc_requires_unverified_service_tls";
    if (service->ssl_enabled != 0) goto cleanup;
    status = "afc_connection_failed";
    if (afc_client_new(device, service, &afc) != AFC_E_SUCCESS) goto cleanup;
    status = "photo_metadata_unavailable";
    if (afc_get_file_info(afc, path, &info) != AFC_E_SUCCESS || !info) goto cleanup;
    int regular = 0, has_size = 0;
    for (int i = 0; info[i] && info[i + 1]; i += 2) {
        if (strcmp(info[i], "st_ifmt") == 0) regular = strcmp(info[i + 1], "S_IFREG") == 0;
        if (strcmp(info[i], "st_size") == 0) {
            char *end = NULL;
            errno = 0;
            if (info[i + 1][0] >= '0' && info[i + 1][0] <= '9') {
                size = strtoull(info[i + 1], &end, 10);
                has_size = errno == 0 && end && *end == '\0';
            }
        }
    }
    status = "metadata_not_regular_sqlite_candidate";
    if (!regular || !has_size || size < 16) goto cleanup;
    status = "metadata_readonly_open_failed";
    if (afc_file_open(afc, path, AFC_FOPEN_RDONLY, &file) != AFC_E_SUCCESS || file == 0) goto cleanup;
    char header[16];
    uint32_t bytes_read = 0;
    status = "metadata_header_read_failed";
    if (afc_file_read(afc, file, header, sizeof(header), &bytes_read) != AFC_E_SUCCESS || bytes_read != sizeof(header)) goto cleanup;
    valid_header = memcmp(header, "SQLite format 3\0", sizeof(header)) == 0;
    status = valid_header ? "sqlite_header_read" : "metadata_header_not_sqlite";
    if (valid_header && copy_mode) {
        status = "metadata_copy_failed";
        if (size > DB_LIMIT || !copy_one(afc, dirfd, "/PhotoData/Photos.sqlite", "Photos.sqlite", DB_LIMIT, 0, &db_copied, &db_stable, &db_present)) goto cleanup;
        if (!copy_one(afc, dirfd, "/PhotoData/Photos.sqlite-wal", "Photos.sqlite-wal", WAL_LIMIT, 1, &wal_copied, &wal_stable, &wal_present)) goto cleanup;
        status = "source_binding_write_failed";
        if (!write_source_binding(dirfd, udid)) goto cleanup;
        status = "metadata_copy_complete";
    }

cleanup:
    if (file && afc) afc_file_close(afc, file);
    if (info) afc_dictionary_free(info);
    if (afc) afc_client_free(afc);
    if (service) lockdownd_service_descriptor_free(service);
    if (lockdown) lockdownd_client_free(lockdown);
    if (device) idevice_free(device);
    if (devices) idevice_device_list_extended_free(devices);
    if (pair) plist_free(pair);
    if (record) { memset(record, 0, record_size); free(record); }
    free(host_id);
    free(buid);
    free(session_id);
    if (dirfd >= 0) close(dirfd);
    if (copy_mode)
        printf("{\"source\":\"iphone_afc\",\"usbDevices\":%d,\"status\":\"%s\",\"candidateBytes\":%" PRIu64 ",\"sqliteHeader\":%s,\"databaseBytesCopied\":%" PRIu64 ",\"databaseStableObserved\":%s,\"walPresent\":%s,\"walBytesCopied\":%" PRIu64 ",\"walStableObserved\":%s,\"stabilityProven\":false,\"assetCounts\":null}\n",
               usb_count, status, size, valid_header ? "true" : "false", db_copied, db_stable ? "true" : "false", wal_present ? "true" : "false", wal_copied, wal_stable ? "true" : "false");
    else
        printf("{\"source\":\"iphone_afc\",\"usbDevices\":%d,\"status\":\"%s\",\"candidateBytes\":%" PRIu64 ",\"sqliteHeader\":%s,\"assetCounts\":null}\n",
               usb_count, status, size, valid_header ? "true" : "false");
    return valid_header && (!copy_mode || strcmp(status, "metadata_copy_complete") == 0) ? 0 : 1;
}
