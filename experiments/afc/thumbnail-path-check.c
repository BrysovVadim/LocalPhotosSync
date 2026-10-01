#define main thumbnail_probe_device_main
#include "thumbnail-candidate.c"
#undef main

static int check(const char *label, int actual, int expected) {
    if (actual == expected) return 1;
    fprintf(stderr, "path check failed: %s\n", label);
    return 0;
}

int main(void) {
    int ok = 1;
    ok &= check("valid DCIM directory", safe_asset_directory("DCIM/100APPLE"), 1);
    ok &= check("valid CPLAssets directory", safe_asset_directory("PhotoData/CPLAssets/3"), 1);
    ok &= check("valid filename", safe_components("IMG_0001.JPG", 0, 255), 1);
    ok &= check("reject empty", safe_components("", 1, 512), 0);
    ok &= check("reject absolute", safe_components("/PhotoData/file", 1, 512), 0);
    ok &= check("reject traversal", safe_components("DCIM/../file", 1, 512), 0);
    ok &= check("reject empty component", safe_components("DCIM//file", 1, 512), 0);
    ok &= check("reject slash in filename", safe_components("folder/file.jpg", 0, 255), 0);
    ok &= check("reject backslash", safe_components("folder\\file.jpg", 0, 255), 0);
    ok &= check("reject control character", safe_components("file\n.jpg", 0, 255), 0);
    ok &= check("reject unknown directory prefix", safe_asset_directory("Private/100APPLE"), 0);
    ok &= check("reject nested DCIM directory", safe_asset_directory("DCIM/100APPLE/subdir"), 0);
    uint8_t binding[SOURCE_BINDING_BYTES];
    ok &= check("create source binding", source_binding_create("local-test-device", binding), 1);
    ok &= check("match source binding", source_binding_matches(binding, sizeof(binding), "local-test-device"), 1);
    ok &= check("reject different device binding", source_binding_matches(binding, sizeof(binding), "other-test-device"), 0);
    ok &= check("reject truncated binding", source_binding_matches(binding, sizeof(binding) - 1, "local-test-device"), 0);
    binding[0] ^= 1;
    ok &= check("reject invalid binding magic", source_binding_matches(binding, sizeof(binding), "local-test-device"), 0);
    memset(binding, 0, sizeof(binding));
    return ok ? 0 : 1;
}
