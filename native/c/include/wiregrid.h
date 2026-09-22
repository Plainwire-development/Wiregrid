#ifndef WIREGRID_H
#define WIREGRID_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WG_ABI_MAJOR 1
#define WG_ABI_MINOR 1
#define WG_PROTOCOL_VERSION 1
#define WG_MAX_ERROR 256
#define WG_DEFAULT_EVENT_QUEUE 1024

typedef struct wg_client wg_client;

typedef enum wg_result {
  WG_OK = 0,
  WG_ERR_ARGUMENT = -1,
  WG_ERR_MEMORY = -2,
  WG_ERR_IO = -3,
  WG_ERR_PROTOCOL = -4,
  WG_ERR_REMOTE = -5,
  WG_ERR_TIMEOUT = -6,
  WG_ERR_OVERFLOW = -7,
  WG_ERR_CLOSED = -8
} wg_result;

typedef struct wg_slice {
  const uint8_t *data;
  size_t len;
} wg_slice;

typedef struct wg_event {
  char *topic;
  uint8_t *payload;
  size_t payload_len;
  char *content_type;
  char *delivery_id;
  char *event_id;
} wg_event;

typedef struct wg_client_options {
  uint32_t timeout_ms;
  size_t event_queue_capacity;
  const char *auth_token;
} wg_client_options;

void wg_client_options_init(wg_client_options *options);
int wg_connect(const char *host, uint16_t port, const char *user_id,
               const wg_client_options *options, wg_client **out_client);
int wg_connect_ex(const char *host, uint16_t port, const char *user_id,
                  const wg_client_options *options, wg_client **out_client,
                  char *error, size_t error_cap);
void wg_close(wg_client *client);

int wg_subscribe(wg_client *client, const char *topic);
int wg_unsubscribe(wg_client *client, const char *topic);
int wg_publish(wg_client *client, const char *topic, const void *payload,
               size_t payload_len, const char *content_type,
               int durable, char *event_id, size_t event_id_cap);
int wg_ack(wg_client *client, const char *delivery_id);
int wg_set_presence(wg_client *client, const char *status);
int wg_join_room(wg_client *client, const char *room);
int wg_leave_room(wg_client *client, const char *room);
int wg_ping(wg_client *client, char *server_version, size_t version_cap);

/* cursor may be NULL. limit 0 asks the server for its default page size.
   out receives a JSON object {"events":[...]}. next_cursor may be NULL. */
int wg_history(wg_client *client, const char *topic, const char *cursor,
               uint32_t limit, void *out, size_t out_cap, size_t *out_len,
               char *next_cursor, size_t next_cursor_cap);

/* timeout_ms == 0 performs a non-blocking poll. */
int wg_poll(wg_client *client, uint32_t timeout_ms, wg_event *out_event);
void wg_event_free(wg_event *event);

const char *wg_last_error(const wg_client *client);
const char *wg_result_string(int result);
uint32_t wg_protocol_version(void);
uint32_t wg_abi_major(void);
uint32_t wg_abi_minor(void);

#ifdef __cplusplus
}
#endif

#endif
