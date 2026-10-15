#include <stddef.h>

size_t ZSTD_decompressBound(const void *src, size_t srcSize);
size_t ZSTD_decompress(void *dst, size_t dstCapacity, const void *src, size_t compressedSize);
unsigned ZSTD_isError(size_t code);
