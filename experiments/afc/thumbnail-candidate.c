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

#define THUMBNAIL_LIMIT (4ULL * 1024ULL * 1024ULL)
#define CHUNK_SIZE 65536
#define REMOTE_LIMIT 1024

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

static int info_values(char **info, uint64_t *size, char **mtime) {
    int regular = 0, has_size = 0, has_mtime = 0;
    for (int i = 0; info && info[i] && info[i + 1]; i += 2) {
        if (!strcmp(info[i], "st_ifmt")) regular = !strcmp(info[i + 1], "S_IFREG");
        if (!strcmp(info[i], "st_size")) {
            char *end = NULL; errno = 0;
            if (info[i + 1][0] >= '0' && info[i + 1][0] <= '9') {
                *size = strtoull(info[i + 1], &end, 10);
                has_size = errno == 0 && end && *end == '\0';
            }
        }
        if (!strcmp(info[i], "st_mtime")) { *mtime = info[i + 1]; has_mtime = 1; }
    }
    return regular && has_size && has_mtime;
}

static const char *image_format(const unsigned char *header, size_t length) {
    if (length >= 3 && header[0] == 0xff && header[1] == 0xd8 && header[2] == 0xff) return "jpeg";
    if (length >= 8 && memcmp(header, "\x89PNG\r\n\x1a\n", 8) == 0) return "png";
    if (length >= 12 && memcmp(header + 4, "ftyp", 4) == 0 &&
        (memcmp(header + 8, "heic", 4) == 0 || memcmp(header + 8, "heix", 4) == 0 ||
         memcmp(header + 8, "hevc", 4) == 0 || memcmp(header + 8, "mif1", 4) == 0 ||
         memcmp(header + 8, "msf1", 4) == 0)) return "heif";
    return "unknown";
}

static int read_candidate(afc_client_t afc, const char *remote, int dirfd,
                          uint64_t *copied, const char **format, int *stable,
                          int *found, const char **status) {
    char **before = NULL, **after = NULL;
    uint64_t expected = 0, after_size = 0, handle = 0;
    char *before_mtime = NULL, *after_mtime = NULL;
    int out = -1, ok = 0;
    afc_error_t e = afc_get_file_info(afc, remote, &before);
    if (e == AFC_E_OBJECT_NOT_FOUND) { *status = "thumbnail_unavailable"; goto done; }
    if (e != AFC_E_SUCCESS || !before || !info_values(before, &expected, &before_mtime)) {
        *status = "thumbnail_stat_failed"; goto done;
    }
    *found = 1;
    if (expected < 8 || expected > THUMBNAIL_LIMIT) { *status = "thumbnail_size_out_of_bounds"; goto done; }
    out = openat(dirfd, "thumbnail.img", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (out < 0) { *status = "local_image_create_failed"; goto done; }
    if (fchmod(out, 0600) != 0) { *status = "local_image_create_failed"; goto done; }
    if (afc_file_open(afc, remote, AFC_FOPEN_RDONLY, &handle) != AFC_E_SUCCESS || !handle) {
        *status = "thumbnail_readonly_open_failed"; goto done;
    }
    unsigned char header[16] = {0};
    size_t header_bytes = 0;
    uint64_t total = 0;
    unsigned char buffer[CHUNK_SIZE];
    while (total < expected) {
        uint32_t received = 0;
        uint32_t request = (uint32_t)((expected - total) < sizeof(buffer) ? expected - total : sizeof(buffer));
        if (afc_file_read(afc, handle, (char *)buffer, request, &received) != AFC_E_SUCCESS || received == 0 || received > request) {
            *status = "thumbnail_read_failed"; goto done;
        }
        size_t position = 0;
        while (position < received) {
            ssize_t written = write(out, buffer + position, received - position);
            if (written <= 0) { *status = "local_image_write_failed"; goto done; }
            position += (size_t)written;
        }
        if (header_bytes < sizeof(header)) {
            size_t take = sizeof(header) - header_bytes;
            if (take > received) take = received;
            memcpy(header + header_bytes, buffer, take);
            header_bytes += take;
        }
        total += received;
        *copied = total;
    }
    if (afc_file_close(afc, handle) != AFC_E_SUCCESS) { handle = 0; *status = "thumbnail_close_failed"; goto done; }
    handle = 0;
    if (afc_get_file_info(afc, remote, &after) != AFC_E_SUCCESS || !after ||
        !info_values(after, &after_size, &after_mtime)) { *status = "thumbnail_after_stat_failed"; goto done; }
    *stable = expected == after_size && strcmp(before_mtime, after_mtime) == 0;
    *format = image_format(header, header_bytes);
    if (strcmp(*format, "unknown") == 0) { *status = "thumbnail_header_unrecognized"; goto done; }
    if (total != expected || fsync(out) != 0) { *status = "local_image_sync_failed"; goto done; }
    *status = "thumbnail_copied";
    ok = 1;
done:
    if (handle) afc_file_close(afc, handle);
    if (out >= 0) close(out);
    if (before) afc_dictionary_free(before);
    if (after) afc_dictionary_free(after);
    return ok;
}

// Run only under an external process deadline. Existing pairing only; AFC calls are readonly.
int main(int argc, char **argv) {
    const char *status = "candidate_path_invalid", *format = "unknown";
    int dirfd = -1, stable = 0, usb_count = 0, count = 0;
    uint64_t bytes_copied = 0;
    idevice_info_t *devices = NULL;
    idevice_t device = NULL;
    lockdownd_client_t lockdown = NULL;
    lockdownd_service_descriptor_t service = NULL;
    afc_client_t afc = NULL;
    char *record = NULL, *host_id = NULL, *buid = NULL, *session_id = NULL;
    uint32_t record_size = 0;
    plist_t pair = NULL;
    const char *udid = NULL;
    int ssl = 0, candidates_statted = 0, candidate_found = 0, exit_code = 1;
    char remote[REMOTE_LIMIT];
    char asset_directory[514], asset_filename[257];
    uint8_t source_binding[SOURCE_BINDING_BYTES] = {0};

    if (argc != 2 || !fgets(asset_directory, sizeof(asset_directory), stdin) ||
        !fgets(asset_filename, sizeof(asset_filename), stdin)) { status = "invalid_arguments"; goto cleanup; }
    size_t directory_length = strlen(asset_directory), filename_length = strlen(asset_filename);
    if (directory_length == 0 || asset_directory[directory_length - 1] != '\n' ||
        filename_length == 0 || asset_filename[filename_length - 1] != '\n') { status = "invalid_arguments"; goto cleanup; }
    asset_directory[directory_length - 1] = '\0';
    asset_filename[filename_length - 1] = '\0';
    if (fread(source_binding, 1, sizeof(source_binding), stdin) != sizeof(source_binding) || fgetc(stdin) != EOF) {
        status = "source_binding_unavailable"; goto cleanup;
    }
    if (!safe_asset_directory(asset_directory) || !safe_components(asset_filename, 0, 255)) goto cleanup;
    struct stat st;
    dirfd = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirfd < 0 || fstat(dirfd, &st) != 0 || !S_ISDIR(st.st_mode)) { status = "local_folder_unavailable"; goto cleanup; }

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
    if (lockdownd_client_new(device, &lockdown, "LocalPhotosSyncThumbnailProbe") != LOCKDOWN_E_SUCCESS) goto cleanup;
    status = "existing_pair_session_failed";
    if (lockdownd_start_session(lockdown, host_id, &session_id, &ssl) != LOCKDOWN_E_SUCCESS || !session_id || !session_id[0]) goto cleanup;
    status = "afc_service_unavailable";
    if (lockdownd_start_service(lockdown, AFC_SERVICE_NAME, &service) != LOCKDOWN_E_SUCCESS || !service || service->port == 0) goto cleanup;
    status = "afc_requires_unverified_service_tls";
    if (service->ssl_enabled != 0) goto cleanup;
    status = "afc_connection_failed";
    if (afc_client_new(device, service, &afc) != AFC_E_SUCCESS) goto cleanup;

    status = "thumbnail_unavailable";
    int length = snprintf(remote, sizeof(remote), "/PhotoData/Thumbnails/V2/%s/%s/5005.JPG", asset_directory, asset_filename);
    if (length < 0 || (size_t)length >= sizeof(remote)) { status = "candidate_path_too_long"; goto cleanup; }
    candidates_statted++;
    if (!read_candidate(afc, remote, dirfd, &bytes_copied, &format, &stable, &candidate_found, &status)) {
        if (strcmp(status, "thumbnail_unavailable") != 0) goto cleanup;
        length = snprintf(remote, sizeof(remote), "/PhotoData/Thumbnails/V2/%s/%s/5003.JPG", asset_directory, asset_filename);
        if (length < 0 || (size_t)length >= sizeof(remote)) { status = "candidate_path_too_long"; goto cleanup; }
        candidates_statted++;
        if (!read_candidate(afc, remote, dirfd, &bytes_copied, &format, &stable, &candidate_found, &status)) goto cleanup;
    }
    status = "thumbnail_copied";
    exit_code = 0;

cleanup:
    if (afc) afc_client_free(afc);
    if (service) lockdownd_service_descriptor_free(service);
    if (lockdown) lockdownd_client_free(lockdown);
    if (device) idevice_free(device);
    if (devices) idevice_device_list_extended_free(devices);
    if (pair) plist_free(pair);
    if (record) { memset(record, 0, record_size); free(record); }
    free(host_id); free(buid); free(session_id);
    memset(source_binding, 0, sizeof(source_binding));
    if (dirfd >= 0) close(dirfd);
    printf("{\"source\":\"iphone_afc\",\"status\":\"%s\",\"candidatePathsStatted\":%d,\"candidateFilesFound\":%d,\"thumbnailBytesCopied\":%" PRIu64 ",\"imageFormat\":\"%s\",\"stableObserved\":%s}\n",
           status, candidates_statted, candidate_found, bytes_copied, format, stable ? "true" : "false");
    return exit_code;
}
