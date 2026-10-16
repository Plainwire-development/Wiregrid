#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wiregrid.h"
#include <time.h>

static uint64_t millis(void) {
  struct timespec ts;
  (void)clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static int adversarial(uint16_t port, const char *scenario) {
  wg_client_options options; wg_client_options_init(&options);
  options.timeout_ms = 120;
  options.event_queue_capacity = 64;
  wg_client *client = NULL;
  char error[WG_MAX_ERROR];
  if (wg_connect_ex("127.0.0.1", port, "alice", &options, &client, error, sizeof(error)) != WG_OK) {
    fprintf(stderr, "%s connect: %s\n", scenario, error); return 20;
  }
  int rc = WG_OK;
  if (strncmp(scenario, "partial_", 8) == 0) {
    if (wg_subscribe(client, "start") != WG_OK) { wg_close(client); return 21; }
    wg_event event;
    if (wg_poll(client, 20, &event) != WG_ERR_TIMEOUT) { wg_close(client); return 22; }
    if (wg_poll(client, 0, &event) != WG_ERR_TIMEOUT) { wg_close(client); return 23; }
    if (wg_ping(client, NULL, 0) != WG_OK || wg_pending_events(client) != 1) { wg_close(client); return 24; }
    if (wg_poll(client, 0, &event) != WG_OK) { wg_close(client); return 25; }
    int valid = event.payload_len == 10 && memcmp(event.payload, "fragmented", 10) == 0;
    wg_event_free(&event);
    wg_close(client);
    return valid ? 0 : 26;
  }
  if (strcmp(scenario, "history_buffers") == 0) {
    char out[64], cursor[16]; size_t len = 999;
    if (wg_history(client, "general", NULL, 101, out, sizeof(out), &len, cursor, sizeof(cursor)) != WG_ERR_ARGUMENT) rc = 30;
    if (wg_history(client, "general", NULL, 10, out, 1, &len, cursor, sizeof(cursor)) != WG_ERR_OVERFLOW || len != 13) rc = 31;
    if (wg_history(client, "general", NULL, 10, out, sizeof(out), &len, cursor, 2) != WG_ERR_OVERFLOW) rc = 32;
    if (wg_history(client, "general", NULL, 10, out, sizeof(out), &len, cursor, sizeof(cursor)) != WG_OK ||
        strcmp(cursor, "cursor-1") != 0 || len != 13 || memcmp(out, "{\"events\":[]}", 13) != 0) rc = 33;
    if (wg_ping(client, NULL, 0) != WG_OK) rc = 34;
    wg_close(client);
    return rc;
  }
  uint64_t start = millis();
  rc = wg_ping(client, NULL, 0);
  uint64_t elapsed = millis() - start;
  int expected = (strcmp(scenario, "slow_response") == 0 || strcmp(scenario, "event_flood") == 0) ? WG_ERR_TIMEOUT : WG_ERR_PROTOCOL;
  if (strcmp(scenario, "final_response") == 0 || strcmp(scenario, "remote_error") == 0) {
    expected = strcmp(scenario, "remote_error") == 0 ? WG_ERR_REMOTE : WG_OK;
    int valid = rc == expected && (expected != WG_ERR_REMOTE || strcmp(wg_last_error(client), "denied") == 0);
    wg_close(client);
    return valid ? 0 : 35;
  }
  int valid = rc == expected && elapsed < 600 && wg_client_fd(client) == -1 && wg_ping(client, NULL, 0) == WG_ERR_CLOSED;
  if (!valid) fprintf(stderr, "%s: got %d expected %d elapsed %llu fd %d\n", scenario, rc, expected, (unsigned long long)elapsed, wg_client_fd(client));
  wg_close(client);
  return valid ? 0 : 36;
}

int main(int argc, char **argv) {
  if (argc != 2 && argc != 3) return 90;
  unsigned long port = strtoul(argv[1], NULL, 10);
  if (argc == 3) return adversarial((uint16_t)port, argv[2]);
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
