#include <stdio.h>
#include <string.h>
#include "wiregrid.h"

int main(void) {
  wg_client *client = NULL;
  wg_client_options options;
  wg_client_options_init(&options);
  if (wg_connect("127.0.0.1", 9567, "c-example", &options, &client) != WG_OK) return 1;
  if (wg_subscribe(client, "general") != WG_OK) return 2;
  const char *hello = "{\"type\":\"message\",\"body\":\"hello from C\"}";
  if (wg_publish(client, "general", hello, strlen(hello), "application/json", 1, NULL, 0) != WG_OK) return 3;
  wg_close(client);
  puts("sent");
  return 0;
}
