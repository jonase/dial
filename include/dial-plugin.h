/**
 * Dial Plugin
 *
 *
 */

#include <stddef.h>

typedef enum DialPluginResult
{
    DIAL_PLUGIN_SUCCESS = 0,
    DIAL_PLUGIN_ERROR_UNKNOWN = -1,
    DIAL_PLUGIN_ERROR_OUT_OF_MEMORY = -2,
    DIAL_PLUGIN_ERROR_INIT = -3,
    DIAL_PLUGIN_ERROR_SCHEMA = -4,
    DIAL_PLUGIN_ERROR_INVOKE = -5,
} DialPluginResult;

DialPluginResult dial_plugin_init(
    size_t args_len,
    const char *args,
    void **handle);

void dial_plugin_deinit(
    void *handle);

DialPluginResult dial_plugin_schema(
    void *handle,
    size_t *schema_len,
    const char **schema_str);

DialPluginResult dial_plugin_invoke(
    void *handle,
    size_t fn_name_len,
    const char *fn_name,
    size_t args_len,
    const char *args,
    size_t *result_len,
    const char **result);

void dial_plugin_free_result(
    void *handle,
    size_t result_len,
    const char *result);

void dial_plugin_last_error_message(
    void *handle,
    size_t error_message_len,
    const char **error_message);
