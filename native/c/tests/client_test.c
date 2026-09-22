#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wiregrid.h"

int main(int argc, char **argv) {
  if (argc != 2) return 90;
  unsigned long port = strtoul(argv[1], NULL, 10);
  wg_client_options options; wg_client_options_init(&options);
  options.timeout_ms = 2000; options.event_queue_capacity = 8;
  wg_client *client = NULL;
  if (wg_connect("127.0.0.1", (uint16_t)port, "alice", &options, &client) != WG_OK) return 1;
  if (wg_subscribe(client, "general") != WG_OK) return 2;
  char event_id[64] = {0};
  const char body[] = "hello";
  if (wg_publish(client, "general", body, 5, "text/plain", 1, event_id, sizeof(event_id)) != WG_OK) return 3;
  if (strcmp(event_id, "evt-1") != 0) return 4;
  wg_event event;
  if (wg_poll(client, 0, &event) != WG_OK) return 5;
  if (strcmp(event.topic, "general") != 0 || event.payload_len != 7 || memcmp(event.payload, "welcome", 7) != 0) return 6;
  if (strcmp(event.delivery_id, "delivery-1") != 0) return 7;
  wg_event_free(&event);
  char version[64] = {0};
  if (wg_ping(client, version, sizeof(version)) != WG_OK || strcmp(version, "1.0.0") != 0) return 8;
  wg_close(client);
  puts("wiregrid C protocol test: ok");
  return 0;
}
