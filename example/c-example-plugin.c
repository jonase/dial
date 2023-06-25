// A simple example plugin in C that can tell the current time and date.
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <time.h>
#include <dial-plugin.h>

const char *schema = "                                          \
    [                                                           \
        {                                                       \
            \"name\": \"current_time\",                         \
            \"description\": \"Get the current date and time\", \
            \"parameters\": {                                   \
                \"type\": \"object\",                           \
                \"properties\": {}                              \
            }                                                   \
        }                                                       \
    ]                                                           \
";

int dial_plugin_init(size_t args_len, const char *args, void **handle)
{
    *handle = NULL;
    return DIAL_PLUGIN_SUCCESS;
}

void dial_plugin_deinit(void *handle)
{
}

int dial_plugin_schema(void *handle, size_t *schema_len, const char **schema_str)
{
    *schema_len = strlen(schema);
    *schema_str = schema;
    return DIAL_PLUGIN_SUCCESS;
}

int dial_plugin_invoke(void *handle, size_t fn_name_len, const char *fn_name, size_t args_len, const char *args, size_t *result_len, const char **result)
{
    time_t current_time = time(NULL);
    char *str = ctime(&current_time);
    size_t len = strlen(str);

    *result_len = len;
    *result = (char *)malloc(sizeof(char) * len);
    if (*result == NULL)
    {
        return DIAL_PLUGIN_ERROR_OUT_OF_MEMORY;
    }
    strcpy(*result, str);

    return DIAL_PLUGIN_SUCCESS;
}

void dial_plugin_free_result(void *handle, size_t result_len, const char *result)
{
    free(result);
}