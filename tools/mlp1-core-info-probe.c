#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

struct retro_system_info {
    const char *library_name;
    const char *library_version;
    const char *valid_extensions;
    bool need_fullpath;
    bool block_extract;
};

typedef void (*retro_get_system_info_fn)(struct retro_system_info *info);

int main(int argc, char **argv)
{
    void *handle;
    void *symbol;
    const char *error;
    retro_get_system_info_fn get_system_info = NULL;
    struct retro_system_info info = {0};

    if (argc != 2) {
        fprintf(stderr, "usage: %s CORE_LIBRETRO_SO\n", argv[0]);
        return 2;
    }

    handle = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
    if (handle == NULL) {
        fprintf(stderr, "cannot load %s: %s\n", argv[1], dlerror());
        return 1;
    }

    dlerror();
    symbol = dlsym(handle, "retro_get_system_info");
    error = dlerror();
    if (error != NULL) {
        fprintf(stderr, "cannot resolve retro_get_system_info in %s: %s\n",
                argv[1], error);
        dlclose(handle);
        return 1;
    }

    /* ISO C does not define a direct void-pointer to function-pointer cast. */
    _Static_assert(sizeof(get_system_info) == sizeof(symbol),
                   "function and object pointers must be the same size");
    memcpy(&get_system_info, &symbol, sizeof(get_system_info));
    get_system_info(&info);

    if (info.library_name == NULL || info.library_name[0] == '\0') {
        fprintf(stderr, "%s returned an empty library_name\n", argv[1]);
        dlclose(handle);
        return 1;
    }

    printf("%s\n", info.library_name);
    dlclose(handle);
    return 0;
}
