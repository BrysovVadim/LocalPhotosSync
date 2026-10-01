#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int safe_components(const char *value, int allow_slash, size_t limit) {
    if (!value || !value[0] || value[0] == '/' || strlen(value) > limit) return 0;
    const char *part = value;
    for (const unsigned char *p = (const unsigned char *)value;; p++) {
        unsigned char ch = *p;
        if (ch == '/' || ch == '\0') {
            size_t length = (const char *)p - part;
            if (length == 0 || (length == 1 && part[0] == '.') ||
                (length == 2 && part[0] == '.' && part[1] == '.')) return 0;
            if (ch == '\0') break;
            if (!allow_slash) return 0;
            part = (const char *)p + 1;
            continue;
        }
        if (ch == '\\' || ch < 0x20 || ch == 0x7f) return 0;
    }
    return 1;
}

static int safe_asset_directory(const char *value) {
    if (!safe_components(value, 1, 512)) return 0;
    if (strncmp(value, "DCIM/", 5) == 0) return safe_components(value + 5, 0, 507);
    if (strncmp(value, "PhotoData/CPLAssets/", 20) == 0) return safe_components(value + 20, 0, 492);
    return 0;
}

static int safe_asset_filename(const char *value) {
    return safe_components(value, 0, 255);
}

#ifdef ASSET_COPY_PATH_TEST
int main(void) {
    const char *good_dirs[] = {"DCIM/100APPLE", "PhotoData/CPLAssets/4"};
    const char *bad_dirs[] = {"", "/DCIM/x", "DCIM/../x", "DCIM//x", "Other/x", "DCIM/a/b", "DCIM/a\\b", "DCIM/a\nb"};
    const char *good_names[] = {"IMG_0042.HEIC", "clip.mov"};
    const char *bad_names[] = {"", "/x", "../x", "a/b", "a\\b", "a\nb", ".", ".."};
    for (size_t i = 0; i < sizeof(good_dirs) / sizeof(good_dirs[0]); i++) if (!safe_asset_directory(good_dirs[i])) return 1;
    for (size_t i = 0; i < sizeof(bad_dirs) / sizeof(bad_dirs[0]); i++) if (safe_asset_directory(bad_dirs[i])) return 2;
    for (size_t i = 0; i < sizeof(good_names) / sizeof(good_names[0]); i++) if (!safe_asset_filename(good_names[i])) return 3;
    for (size_t i = 0; i < sizeof(bad_names) / sizeof(bad_names[0]); i++) if (safe_asset_filename(bad_names[i])) return 4;
    return 0;
}
#else

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>
#include <usbmuxd.h>
#include <plist/plist.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <sys/stat.h>
#include <unistd.h>
#include "source-binding.h"

#define REMOTE_LIMIT 1024
#define COPY_LIMIT (32ULL * 1024ULL * 1024ULL)
#define CHUNK_SIZE 65536

static int read_line(char *buffer, size_t capacity) {
    if (!fgets(buffer, (int)capacity, stdin)) return 0;
    size_t length = strlen(buffer);
    return length > 0 && buffer[length - 1] == '\n';
}

static int stat_values(char **info, uint64_t *size, char *mtime, size_t mtime_capacity) {
    int regular = 0, has_size = 0, has_mtime = 0;
    for (int i = 0; info && info[i] && info[i + 1]; i += 2) {
        if (!strcmp(info[i], "st_ifmt")) regular = !strcmp(info[i + 1], "S_IFREG");
        if (!strcmp(info[i], "st_size")) {
            const char *text = info[i + 1];
            if (!text[0]) continue;
            for (const unsigned char *p = (const unsigned char *)text; *p; p++) if (!isdigit(*p)) return 0;
            char *end = NULL;
            errno = 0;
            unsigned long long parsed = strtoull(text, &end, 10);
            if (errno || !end || *end) return 0;
            *size = (uint64_t)parsed;
            has_size = 1;
        }
        if (!strcmp(info[i], "st_mtime")) {
            size_t length = strlen(info[i + 1]);
            if (length >= mtime_capacity) return 0;
            memcpy(mtime, info[i + 1], length + 1);
            has_mtime = 1;
        }
    }
    return regular && has_size && has_mtime;
}

static int write_all(int descriptor, const unsigned char *bytes, size_t length) {
    size_t position = 0;
    while (position < length) {
        ssize_t written = write(descriptor, bytes + position, length - position);
        if (written <= 0) return 0;
        position += (size_t)written;
    }
    return 1;
}

static int write_copy_receipt(int dirfd, uint64_t declared, uint64_t copied,
                              int stable, const uint8_t digest[CC_SHA256_DIGEST_LENGTH]) {
    static const char hex[] = "0123456789abcdef";
    char digest_hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        digest_hex[i * 2] = hex[digest[i] >> 4];
        digest_hex[i * 2 + 1] = hex[digest[i] & 0x0f];
    }
    digest_hex[sizeof(digest_hex) - 1] = '\0';
    char receipt[256];
    int length = snprintf(receipt, sizeof(receipt),
        "{\"source\":\"iphone_afc\",\"status\":\"asset_copy_complete\",\"declaredBytes\":%" PRIu64
        ",\"copiedBytes\":%" PRIu64 ",\"stableObserved\":%s,\"receivedStreamSHA256\":\"%s\"}\n",
        declared, copied, stable ? "true" : "false", digest_hex);
    if (length < 0 || (size_t)length >= sizeof(receipt)) return 0;
    int descriptor = openat(dirfd, "copy-receipt.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) return 0;
    int ok = fchmod(descriptor, 0600) == 0 && write_all(descriptor, (const unsigned char *)receipt, (size_t)length) && fsync(descriptor) == 0;
    if (close(descriptor) != 0) ok = 0;
    memset(digest_hex, 0, sizeof(digest_hex));
    memset(receipt, 0, sizeof(receipt));
    return ok;
}

int main(int argc, char **argv) {
    idevice_t device = NULL;
    lockdownd_client_t lockdown = NULL;
    lockdownd_service_descriptor_t service = NULL;
    afc_client_t afc = NULL;
    idevice_info_t *devices = NULL;
    int count = 0, usb_count = 0, output_fd = -1, dirfd = -1, exit_code = 1;
    const char *udid = NULL, *status = "invalid_arguments";
    char *record = NULL, *host_id = NULL, *buid = NULL, *session_id = NULL;
    uint32_t record_size = 0;
    plist_t pair = NULL;
    int ssl = 0, stable = 0;
    uint64_t declared = 0, after_size = 0, copied = 0, handle = 0;
    uint8_t source_binding[SOURCE_BINDING_BYTES] = {0}, digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256_CTX digest_context;
    memset(&digest_context, 0, sizeof(digest_context));
    int digest_started = 0, digest_finished = 0;
    char directory[513] = {0}, filename[256] = {0}, remote[REMOTE_LIMIT] = {0};
    char before_mtime[256] = {0}, after_mtime[256] = {0};

    if (argc != 2 || !read_line(directory, sizeof(directory)) || !read_line(filename, sizeof(filename)) ||
        directory[strlen(directory) - 1] != '\n' || filename[strlen(filename) - 1] != '\n') goto cleanup;
    directory[strlen(directory) - 1] = '\0';
    filename[strlen(filename) - 1] = '\0';
    if (fread(source_binding, 1, sizeof(source_binding), stdin) != sizeof(source_binding) || fgetc(stdin) != EOF) {
        status = "source_binding_unavailable"; goto cleanup;
    }
    if (!safe_asset_directory(directory) || !safe_asset_filename(filename)) { status = "invalid_arguments"; goto cleanup; }
    struct stat local_info;
    dirfd = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirfd < 0 || fstat(dirfd, &local_info) != 0 || !S_ISDIR(local_info.st_mode)) { status = "local_folder_unavailable"; goto cleanup; }

    unsetenv("USBMUXD_SOCKET_ADDRESS");
    idevice_set_debug_level(0);
    status = "device_discovery_failed";
    if (idevice_get_device_list_extended(&devices, &count) != IDEVICE_E_SUCCESS) goto cleanup;
    for (int i = 0; i < count; i++) if (devices[i]->conn_type == CONNECTION_USBMUXD) { usb_count++; udid = devices[i]->udid; }
    status = "requires_exactly_one_usb_device";
    if (usb_count != 1 || !udid) goto cleanup;
    status = "source_binding_unavailable";
    if (memcmp(source_binding, SOURCE_BINDING_MAGIC, SOURCE_BINDING_MAGIC_BYTES) != 0) goto cleanup;
    status = "source_binding_mismatch";
    if (!source_binding_matches(source_binding, sizeof(source_binding), udid)) goto cleanup;
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
    if (lockdownd_client_new(device, &lockdown, "LocalPhotosSyncAssetCopyProbe") != LOCKDOWN_E_SUCCESS) goto cleanup;
    status = "existing_pair_session_failed";
    if (lockdownd_start_session(lockdown, host_id, &session_id, &ssl) != LOCKDOWN_E_SUCCESS || !session_id || !session_id[0]) goto cleanup;
    status = "afc_service_unavailable";
    if (lockdownd_start_service(lockdown, AFC_SERVICE_NAME, &service) != LOCKDOWN_E_SUCCESS || !service || service->port == 0) goto cleanup;
    status = "afc_requires_unverified_service_tls";
    if (service->ssl_enabled != 0) goto cleanup;
    status = "afc_connection_failed";
    if (afc_client_new(device, service, &afc) != AFC_E_SUCCESS) goto cleanup;

    int path_length = snprintf(remote, sizeof(remote), "/%s/%s", directory, filename);
    if (path_length < 0 || (size_t)path_length >= sizeof(remote)) { status = "candidate_path_too_long"; goto cleanup; }
    char **before = NULL;
    afc_error_t stat_result = afc_get_file_info(afc, remote, &before);
    if (stat_result == AFC_E_OBJECT_NOT_FOUND) { status = "asset_unavailable"; goto cleanup; }
    if (stat_result != AFC_E_SUCCESS || !before || !stat_values(before, &declared, before_mtime, sizeof(before_mtime))) {
        status = "asset_stat_failed"; if (before) afc_dictionary_free(before); goto cleanup;
    }
    afc_dictionary_free(before);
    if (declared > COPY_LIMIT) { status = "asset_size_out_of_bounds"; goto cleanup; }
    output_fd = openat(dirfd, "media.bin", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (output_fd < 0) { status = "local_file_create_failed"; goto cleanup; }
    if (fchmod(output_fd, 0600) != 0) { status = "local_file_create_failed"; goto cleanup; }
    if (afc_file_open(afc, remote, AFC_FOPEN_RDONLY, &handle) != AFC_E_SUCCESS || !handle) {
        status = "asset_readonly_open_failed"; goto cleanup;
    }
    if (CC_SHA256_Init(&digest_context) != 1) { status = "asset_hash_failed"; goto cleanup; }
    digest_started = 1;
    unsigned char buffer[CHUNK_SIZE];
    while (copied < declared) {
        uint32_t received = 0;
        uint32_t request = (uint32_t)((declared - copied) < sizeof(buffer) ? declared - copied : sizeof(buffer));
        if (afc_file_read(afc, handle, (char *)buffer, request, &received) != AFC_E_SUCCESS || received == 0 || received > request) {
            status = "asset_read_failed"; goto cleanup;
        }
        if (CC_SHA256_Update(&digest_context, buffer, received) != 1) { status = "asset_hash_failed"; goto cleanup; }
        if (!write_all(output_fd, buffer, received)) { status = "local_write_failed"; goto cleanup; }
        copied += received;
    }
    if (afc_file_close(afc, handle) != AFC_E_SUCCESS) { handle = 0; status = "asset_close_failed"; goto cleanup; }
    handle = 0;
    if (copied != declared) { status = "asset_read_failed"; goto cleanup; }
    if (fsync(output_fd) != 0) { status = "local_sync_failed"; goto cleanup; }
    if (close(output_fd) != 0) { output_fd = -1; status = "local_close_failed"; goto cleanup; }
    output_fd = -1;

    char **after = NULL;
    if (afc_get_file_info(afc, remote, &after) != AFC_E_SUCCESS || !after || !stat_values(after, &after_size, after_mtime, sizeof(after_mtime))) {
        status = "asset_stat_after_failed"; if (after) afc_dictionary_free(after); goto cleanup;
    }
    afc_dictionary_free(after);
    if (after_size != declared || copied != declared) { status = "asset_changed"; goto cleanup; }
    stable = strcmp(before_mtime, after_mtime) == 0;
    if (CC_SHA256_Final(digest, &digest_context) != 1) { status = "asset_hash_failed"; goto cleanup; }
    digest_finished = 1;
    status = "copy_receipt_failed";
    if (!write_copy_receipt(dirfd, declared, copied, stable, digest)) goto cleanup;
    status = "asset_copy_complete";
    exit_code = 0;

cleanup:
    if (handle && afc) afc_file_close(afc, handle);
    if (output_fd >= 0) close(output_fd);
    if (afc) afc_client_free(afc);
    if (service) lockdownd_service_descriptor_free(service);
    if (lockdown) lockdownd_client_free(lockdown);
    if (device) idevice_free(device);
    if (devices) idevice_device_list_extended_free(devices);
    if (pair) plist_free(pair);
    if (record) { memset(record, 0, record_size); free(record); }
    free(host_id); free(buid); free(session_id);
    memset(source_binding, 0, sizeof(source_binding));
    memset(buffer, 0, sizeof(buffer));
    memset(&digest_context, 0, sizeof(digest_context));
    if (digest_started && !digest_finished) memset(digest, 0, sizeof(digest));
    if (dirfd >= 0) close(dirfd);
    printf("{\"source\":\"iphone_afc\",\"status\":\"%s\",\"copiedBytes\":%" PRIu64 ",\"stableObserved\":%s,\"localFolder\":\"%s\"}\n",
           status, copied, stable ? "true" : "false", argc == 2 ? argv[1] : "");
    memset(digest, 0, sizeof(digest));
    return exit_code;
}
#endif
