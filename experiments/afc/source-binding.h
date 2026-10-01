#ifndef LOCAL_PHOTOS_SYNC_SOURCE_BINDING_H
#define LOCAL_PHOTOS_SYNC_SOURCE_BINDING_H

#include <CommonCrypto/CommonDigest.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define SOURCE_BINDING_MAGIC "LPSBIND1"
#define SOURCE_BINDING_MAGIC_BYTES 8
#define SOURCE_BINDING_SALT_BYTES 32
#define SOURCE_BINDING_DIGEST_BYTES 32
#define SOURCE_BINDING_BYTES (SOURCE_BINDING_MAGIC_BYTES + SOURCE_BINDING_SALT_BYTES + SOURCE_BINDING_DIGEST_BYTES)

static inline int source_binding_create(const char *udid, uint8_t binding[SOURCE_BINDING_BYTES]) {
    if (!udid || !udid[0]) return 0;
    size_t udid_length = strlen(udid);
    if (udid_length > UINT32_MAX) return 0;
    memcpy(binding, SOURCE_BINDING_MAGIC, SOURCE_BINDING_MAGIC_BYTES);
    arc4random_buf(binding + SOURCE_BINDING_MAGIC_BYTES, SOURCE_BINDING_SALT_BYTES);
    CC_SHA256_CTX context;
    int ok = CC_SHA256_Init(&context) == 1;
    if (ok) ok = CC_SHA256_Update(&context, binding + SOURCE_BINDING_MAGIC_BYTES, SOURCE_BINDING_SALT_BYTES) == 1;
    if (ok) ok = CC_SHA256_Update(&context, (const uint8_t *)udid, (CC_LONG)udid_length) == 1;
    if (ok) ok = CC_SHA256_Final(binding + SOURCE_BINDING_MAGIC_BYTES + SOURCE_BINDING_SALT_BYTES, &context) == 1;
    memset(&context, 0, sizeof(context));
    if (!ok) memset(binding, 0, SOURCE_BINDING_BYTES);
    return ok;
}

static inline int source_binding_matches(const uint8_t *binding, size_t length, const char *udid) {
    if (!binding || length != SOURCE_BINDING_BYTES ||
        memcmp(binding, SOURCE_BINDING_MAGIC, SOURCE_BINDING_MAGIC_BYTES) != 0 || !udid || !udid[0]) return 0;
    size_t udid_length = strlen(udid);
    if (udid_length > UINT32_MAX) return 0;
    uint8_t digest[SOURCE_BINDING_DIGEST_BYTES];
    CC_SHA256_CTX context;
    int ok = CC_SHA256_Init(&context) == 1;
    if (ok) ok = CC_SHA256_Update(&context, binding + SOURCE_BINDING_MAGIC_BYTES, SOURCE_BINDING_SALT_BYTES) == 1;
    if (ok) ok = CC_SHA256_Update(&context, (const uint8_t *)udid, (CC_LONG)udid_length) == 1;
    if (ok) ok = CC_SHA256_Final(digest, &context) == 1;
    memset(&context, 0, sizeof(context));
    if (!ok) { memset(digest, 0, sizeof(digest)); return 0; }
    uint8_t difference = 0;
    const uint8_t *expected = binding + SOURCE_BINDING_MAGIC_BYTES + SOURCE_BINDING_SALT_BYTES;
    for (size_t i = 0; i < SOURCE_BINDING_DIGEST_BYTES; i++) difference |= digest[i] ^ expected[i];
    memset(digest, 0, sizeof(digest));
    return difference == 0;
}

#endif
