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

#ifdef ASSET_HEADER_PATH_TEST
int main(void) {
    const char *valid_directories[] = {"DCIM/100APPLE", "PhotoData/CPLAssets/3"};
    const char *invalid_directories[] = {
        "", "/DCIM/100APPLE", "DCIM/../x", "DCIM//x", "DCIM/.", "Other/x",
        "DCIM/x/y", "PhotoData/CPLAssets/../x", "DCIM/x\\y", "DCIM/x\ny"
    };
    const char *valid_filenames[] = {"IMG_0001.HEIC", "asset-1.mov"};
    const char *invalid_filenames[] = {"", "/x", "../x", "a/b", "a\\b", "a\nb", ".", ".."};
    for (size_t i = 0; i < sizeof(valid_directories) / sizeof(valid_directories[0]); i++)
        if (!safe_asset_directory(valid_directories[i])) return 1;
    for (size_t i = 0; i < sizeof(invalid_directories) / sizeof(invalid_directories[0]); i++)
        if (safe_asset_directory(invalid_directories[i])) return 2;
    for (size_t i = 0; i < sizeof(valid_filenames) / sizeof(valid_filenames[0]); i++)
        if (!safe_asset_filename(valid_filenames[i])) return 3;
    for (size_t i = 0; i < sizeof(invalid_filenames) / sizeof(invalid_filenames[0]); i++)
        if (safe_asset_filename(invalid_filenames[i])) return 4;
    return 0;
}
#else

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>
#include <usbmuxd.h>
#include <plist/plist.h>
#include <errno.h>
#include <inttypes.h>
#include <unistd.h>
#include "source-binding.h"

#define REMOTE_LIMIT 1024
#define MAX_ASSET_SIZE (1024ULL * 1024ULL * 1024ULL)
#define MAX_HEADER_BYTES 16

static int read_line(char *buffer, size_t capacity) {
    if (!fgets(buffer, (int)capacity, stdin)) return 0;
    size_t length = strlen(buffer);
    return length > 0 && buffer[length - 1] == '\n';
}

static int get_file_size(char **info, uint64_t *size) {
    int regular = 0, has_size = 0;
    for (int i = 0; info && info[i] && info[i + 1]; i += 2) {
        if (!strcmp(info[i], "st_ifmt")) regular = !strcmp(info[i + 1], "S_IFREG");
        if (!strcmp(info[i], "st_size")) {
            const char *text = info[i + 1];
            if (!text[0]) continue;
            for (const unsigned char *p = (const unsigned char *)text; *p; p++)
                if (!isdigit(*p)) return 0;
            char *end = NULL;
            errno = 0;
            unsigned long long parsed = strtoull(text, &end, 10);
            if (errno || !end || *end) return 0;
            *size = (uint64_t)parsed;
            has_size = 1;
        }
    }
    return regular && has_size;
}

static const char *classify_header(const unsigned char *header, size_t length) {
    if (length >= 3 && header[0] == 0xff && header[1] == 0xd8 && header[2] == 0xff) return "jpeg";
    if (length >= 8 && memcmp(header, "\x89PNG\r\n\x1a\n", 8) == 0) return "png";
    if (length >= 12 && memcmp(header + 4, "ftyp", 4) == 0) return "isobmff";
    return "unknown";
}

int main(void) {
    idevice_t device = NULL;
    lockdownd_client_t lockdown = NULL;
    lockdownd_service_descriptor_t service = NULL;
    afc_client_t afc = NULL;
    idevice_info_t *devices = NULL;
    int count = 0, usb_count = 0, exit_code = 1;
    const char *udid = NULL, *status = "invalid_arguments", *format = "unknown";
    char *record = NULL, *host_id = NULL, *buid = NULL, *session_id = NULL;
    uint32_t record_size = 0;
    plist_t pair = NULL;
    int ssl = 0, found = 0;
    uint64_t declared_bytes = 0, bytes_read = 0, handle = 0;
    uint8_t source_binding[SOURCE_BINDING_BYTES] = {0};
    char directory[513] = {0}, filename[256] = {0}, remote[REMOTE_LIMIT] = {0};

    if (!read_line(directory, sizeof(directory)) || !read_line(filename, sizeof(filename)) ||
        directory[strlen(directory) - 1] != '\n' || filename[strlen(filename) - 1] != '\n') {
        status = "invalid_arguments"; goto cleanup;
    }
    directory[strlen(directory) - 1] = '\0';
    filename[strlen(filename) - 1] = '\0';
    if (fread(source_binding, 1, sizeof(source_binding), stdin) != sizeof(source_binding) || fgetc(stdin) != EOF) {
        status = "source_binding_unavailable"; goto cleanup;
    }
    if (!safe_asset_directory(directory) || !safe_asset_filename(filename)) {
        status = "invalid_arguments"; goto cleanup;
    }

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
    if (lockdownd_client_new(device, &lockdown, "LocalPhotosSyncAssetHeaderProbe") != LOCKDOWN_E_SUCCESS) goto cleanup;
    status = "existing_pair_session_failed";
    if (lockdownd_start_session(lockdown, host_id, &session_id, &ssl) != LOCKDOWN_E_SUCCESS || !session_id || !session_id[0]) goto cleanup;
    status = "afc_service_unavailable";
    if (lockdownd_start_service(lockdown, AFC_SERVICE_NAME, &service) != LOCKDOWN_E_SUCCESS || !service || service->port == 0) goto cleanup;
    status = "afc_requires_unverified_service_tls";
    if (service->ssl_enabled != 0) goto cleanup;
    status = "afc_connection_failed";
    if (afc_client_new(device, service, &afc) != AFC_E_SUCCESS) goto cleanup;

    int length = snprintf(remote, sizeof(remote), "/%s/%s", directory, filename);
    if (length < 0 || (size_t)length >= sizeof(remote)) { status = "candidate_path_too_long"; goto cleanup; }
    char **info = NULL;
    afc_error_t info_result = afc_get_file_info(afc, remote, &info);
    if (info_result == AFC_E_OBJECT_NOT_FOUND) { status = "asset_unavailable"; goto cleanup; }
    if (info_result != AFC_E_SUCCESS || !info || !get_file_size(info, &declared_bytes)) {
        status = "asset_stat_failed"; if (info) afc_dictionary_free(info); goto cleanup;
    }
    afc_dictionary_free(info);
    found = 1;
    if (declared_bytes > MAX_ASSET_SIZE) { status = "asset_size_out_of_bounds"; goto cleanup; }
    if (afc_file_open(afc, remote, AFC_FOPEN_RDONLY, &handle) != AFC_E_SUCCESS || !handle) {
        status = "asset_readonly_open_failed"; goto cleanup;
    }
    unsigned char header[MAX_HEADER_BYTES] = {0};
    uint32_t received = 0;
    uint32_t request = declared_bytes < MAX_HEADER_BYTES ? (uint32_t)declared_bytes : MAX_HEADER_BYTES;
    if (request > 0 && afc_file_read(afc, handle, (char *)header, request, &received) != AFC_E_SUCCESS) {
        status = "asset_header_read_failed"; goto cleanup;
    }
    if (received > request) { status = "asset_header_read_failed"; goto cleanup; }
    bytes_read = received;
    format = classify_header(header, (size_t)received);
    status = "asset_header_read";
    exit_code = 0;

cleanup:
    if (handle && afc) {
        if (afc_file_close(afc, handle) != AFC_E_SUCCESS && exit_code == 0) {
            status = "asset_close_failed"; exit_code = 1;
        }
    }
    if (afc) afc_client_free(afc);
    if (service) lockdownd_service_descriptor_free(service);
    if (lockdown) lockdownd_client_free(lockdown);
    if (device) idevice_free(device);
    if (devices) idevice_device_list_extended_free(devices);
    if (pair) plist_free(pair);
    if (record) { memset(record, 0, record_size); free(record); }
    free(host_id); free(buid); free(session_id);
    memset(source_binding, 0, sizeof(source_binding));
    printf("{\"source\":\"iphone_afc\",\"status\":\"%s\",\"found\":%d,\"declaredBytes\":%" PRIu64 ",\"bytesRead\":%" PRIu64 ",\"format\":\"%s\"}\n",
           status, found, declared_bytes, bytes_read, format);
    return exit_code;
}
#endif
