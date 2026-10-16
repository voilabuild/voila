#pragma once

#include <stddef.h>
#include <stdint.h>

/// HTTP GET via libcurl easy interface. On success (0), *out_data is malloc'd
/// and must be released with voila_curl_free.
int voila_curl_http_get(const char *url, const char *bearer_token, long timeout_seconds,
                        uint8_t **out_data, size_t *out_len);

void voila_curl_free(void *ptr);
