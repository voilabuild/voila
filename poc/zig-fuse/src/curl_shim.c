#include "curl_shim.h"

#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>

struct MemBuf {
    uint8_t *data;
    size_t len;
    size_t cap;
};

static size_t write_cb(void *contents, size_t size, size_t nmemb, void *userp) {
    size_t realsize = size * nmemb;
    struct MemBuf *mem = (struct MemBuf *)userp;
    size_t need = mem->len + realsize;
    if (need > mem->cap) {
        size_t new_cap = mem->cap ? mem->cap : 4096;
        while (new_cap < need) {
            new_cap *= 2;
        }
        uint8_t *p = (uint8_t *)realloc(mem->data, new_cap);
        if (!p) {
            return 0;
        }
        mem->data = p;
        mem->cap = new_cap;
    }
    memcpy(mem->data + mem->len, contents, realsize);
    mem->len += realsize;
    return realsize;
}

int voila_curl_http_get(const char *url, const char *bearer_token, long timeout_seconds,
                        uint8_t **out_data, size_t *out_len) {
    if (!url || !out_data || !out_len) {
        return -1;
    }
    *out_data = NULL;
    *out_len = 0;

    static int curl_inited = 0;
    if (!curl_inited) {
        if (curl_global_init(CURL_GLOBAL_DEFAULT) != 0) {
            return -2;
        }
        curl_inited = 1;
    }

    CURL *curl = curl_easy_init();
    if (!curl) {
        return -2;
    }

    struct MemBuf buf = {.data = NULL, .len = 0, .cap = 0};
    struct curl_slist *headers = NULL;
    char auth_line[8192];

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)&buf);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_seconds > 0 ? timeout_seconds : 120L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "voila-zig-registry/1.0");

    if (bearer_token && bearer_token[0] != '\0') {
        int n = snprintf(auth_line, sizeof(auth_line), "Authorization: Bearer %s", bearer_token);
        if (n < 0 || (size_t)n >= sizeof(auth_line)) {
            curl_easy_cleanup(curl);
            free(buf.data);
            return -3;
        }
        headers = curl_slist_append(headers, auth_line);
        if (!headers) {
            curl_easy_cleanup(curl);
            free(buf.data);
            return -4;
        }
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    }

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK || http_code < 200 || http_code >= 300) {
        free(buf.data);
        return -5;
    }

    *out_data = buf.data;
    *out_len = buf.len;
    return 0;
}

void voila_curl_free(void *ptr) {
    free(ptr);
}
