#define _POSIX_C_SOURCE 200809L
#include "wiregrid.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define WG_KIND_REQUEST 0
#define WG_KIND_RESPONSE 1
#define WG_KIND_EVENT 2
#define WG_OP_HELLO 1
#define WG_OP_SUBSCRIBE 2
#define WG_OP_UNSUBSCRIBE 3
#define WG_OP_PUBLISH 4
#define WG_OP_ACK 5
#define WG_OP_PRESENCE 6
#define WG_OP_JOIN_ROOM 7
#define WG_OP_LEAVE_ROOM 8
#define WG_OP_PING 9
#define WG_OP_HISTORY 10
#define WG_OP_EVENT 64

#define WG_F_INSTANCE 1
#define WG_F_USER_ID 2
#define WG_F_TOPIC 3
#define WG_F_PAYLOAD 4
#define WG_F_CONTENT_TYPE 5
#define WG_F_DELIVERY_ID 6
#define WG_F_STATUS 7
#define WG_F_ROOM 8
#define WG_F_EVENT_ID 9
#define WG_F_ERROR 10
#define WG_F_CLASS 11
#define WG_F_SERVER_VERSION 12
#define WG_F_SESSION_ID 13
#define WG_F_AUTH_TOKEN 14
#define WG_F_CURSOR 15
#define WG_F_LIMIT 16

#define WG_MAX_FRAME (2u * 1024u * 1024u)
#define WG_MAX_FIELDS 32u
#define WG_MAX_FIELD (1024u * 1024u)

typedef struct wg_owned_event {
  wg_event value;
} wg_owned_event;

struct wg_client {
  int fd;
  uint32_t next_request_id;
  uint32_t timeout_ms;
  char error[WG_MAX_ERROR];
  wg_owned_event *queue;
  size_t queue_cap;
  size_t queue_head;
  size_t queue_len;
};

typedef struct wg_field_view {
  uint8_t tag;
  const uint8_t *data;
  uint32_t len;
} wg_field_view;

typedef struct wg_frame_view {
  uint8_t kind;
  uint8_t op;
  uint32_t request_id;
  wg_field_view fields[WG_MAX_FIELDS];
  size_t field_count;
} wg_frame_view;

static void set_error(wg_client *c, const char *message) {
  if (!c) return;
  if (!message) message = "unknown error";
  snprintf(c->error, sizeof(c->error), "%s", message);
}

static int connect_fail(int code, char *error, size_t error_cap) {
  if (error && error_cap) snprintf(error, error_cap, "%s", wg_result_string(code));
  return code;
}

static int wait_fd(int fd, short events, uint32_t timeout_ms) {
  struct pollfd p = {.fd = fd, .events = events, .revents = 0};
  int rc;
  do { rc = poll(&p, 1, (int)timeout_ms); } while (rc < 0 && errno == EINTR);
  if (rc == 0) return WG_ERR_TIMEOUT;
  if (rc < 0) return WG_ERR_IO;
  if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) return WG_ERR_CLOSED;
  return WG_OK;
}

static int write_all(wg_client *c, const uint8_t *buf, size_t len) {
  if (!c || c->fd < 0) return WG_ERR_CLOSED;
  size_t off = 0;
  while (off < len) {
    int ready = wait_fd(c->fd, POLLOUT, c->timeout_ms);
    if (ready != WG_OK) return ready;
    ssize_t n = send(c->fd, buf + off, len - off, MSG_NOSIGNAL);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return WG_ERR_IO;
    off += (size_t)n;
  }
  return WG_OK;
}

static int read_all(wg_client *c, uint8_t *buf, size_t len, uint32_t timeout_ms) {
  if (!c || c->fd < 0) return WG_ERR_CLOSED;
  size_t off = 0;
  while (off < len) {
    int ready = wait_fd(c->fd, POLLIN, timeout_ms);
    if (ready != WG_OK) return ready;
    ssize_t n = recv(c->fd, buf + off, len - off, 0);
    if (n < 0 && errno == EINTR) continue;
    if (n == 0) return WG_ERR_CLOSED;
    if (n < 0) return WG_ERR_IO;
    off += (size_t)n;
  }
  return WG_OK;
}

static void put_u32(uint8_t *p, uint32_t value) {
  uint32_t n = htonl(value);
  memcpy(p, &n, 4);
}

static uint32_t get_u32(const uint8_t *p) {
  uint32_t n;
  memcpy(&n, p, 4);
  return ntohl(n);
}

static int append_field(uint8_t *buf, size_t cap, size_t *len, uint8_t tag,
                        const void *data, size_t data_len) {
  if (!buf || !len || (!data && data_len) || data_len > WG_MAX_FIELD) return WG_ERR_ARGUMENT;
  if (*len > cap || cap - *len < 5u + data_len) return WG_ERR_OVERFLOW;
  buf[(*len)++] = tag;
  put_u32(buf + *len, (uint32_t)data_len);
  *len += 4;
  if (data_len) memcpy(buf + *len, data, data_len);
  *len += data_len;
  return WG_OK;
}

static int send_request(wg_client *c, uint8_t op, uint32_t request_id,
                        const uint8_t *fields, size_t fields_len) {
  size_t frame_len = 7u + fields_len;
  if (frame_len > WG_MAX_FRAME) return WG_ERR_OVERFLOW;
  uint8_t *packet = malloc(4u + frame_len);
  if (!packet) return WG_ERR_MEMORY;
  put_u32(packet, (uint32_t)frame_len);
  packet[4] = WG_PROTOCOL_VERSION;
  packet[5] = WG_KIND_REQUEST;
  packet[6] = op;
  put_u32(packet + 7, request_id);
  if (fields_len) memcpy(packet + 11, fields, fields_len);
  int rc = write_all(c, packet, 4u + frame_len);
  free(packet);
  return rc;
}

static int read_frame(wg_client *c, uint32_t timeout_ms, uint8_t **out, size_t *out_len) {
  uint8_t length[4];
  int rc = read_all(c, length, 4, timeout_ms);
  if (rc != WG_OK) return rc;
  uint32_t len = get_u32(length);
  if (len < 7 || len > WG_MAX_FRAME) return WG_ERR_PROTOCOL;
  uint8_t *buf = malloc(len);
  if (!buf) return WG_ERR_MEMORY;
  rc = read_all(c, buf, len, timeout_ms);
  if (rc != WG_OK) { free(buf); return rc; }
  *out = buf;
  *out_len = len;
  return WG_OK;
}

static int parse_frame(const uint8_t *buf, size_t len, wg_frame_view *out) {
  if (!buf || !out || len < 7 || buf[0] != WG_PROTOCOL_VERSION) return WG_ERR_PROTOCOL;
  memset(out, 0, sizeof(*out));
  out->kind = buf[1];
  out->op = buf[2];
  out->request_id = get_u32(buf + 3);
  size_t off = 7;
  while (off < len) {
    if (out->field_count >= WG_MAX_FIELDS || len - off < 5) return WG_ERR_PROTOCOL;
    uint8_t tag = buf[off++];
    uint32_t field_len = get_u32(buf + off);
    off += 4;
    if (field_len > WG_MAX_FIELD || field_len > len - off) return WG_ERR_PROTOCOL;
    for (size_t i = 0; i < out->field_count; i++)
      if (out->fields[i].tag == tag) return WG_ERR_PROTOCOL;
    out->fields[out->field_count++] = (wg_field_view){tag, buf + off, field_len};
    off += field_len;
  }
  return WG_OK;
}

static const wg_field_view *field(const wg_frame_view *frame, uint8_t tag) {
  for (size_t i = 0; i < frame->field_count; i++) if (frame->fields[i].tag == tag) return &frame->fields[i];
  return NULL;
}

static char *dup_field(const wg_field_view *f) {
  if (!f) return NULL;
  char *s = malloc((size_t)f->len + 1u);
  if (!s) return NULL;
  if (f->len) memcpy(s, f->data, f->len);
  s[f->len] = '\0';
  return s;
}

void wg_event_free(wg_event *event) {
  if (!event) return;
  free(event->topic);
  free(event->payload);
  free(event->content_type);
  free(event->delivery_id);
  free(event->event_id);
  memset(event, 0, sizeof(*event));
}

static int event_from_frame(const wg_frame_view *frame, wg_event *out) {
  memset(out, 0, sizeof(*out));
  const wg_field_view *topic = field(frame, WG_F_TOPIC);
  const wg_field_view *payload = field(frame, WG_F_PAYLOAD);
  if (!topic || !payload) return WG_ERR_PROTOCOL;
  out->topic = dup_field(topic);
  out->content_type = dup_field(field(frame, WG_F_CONTENT_TYPE));
  out->delivery_id = dup_field(field(frame, WG_F_DELIVERY_ID));
  out->event_id = dup_field(field(frame, WG_F_EVENT_ID));
  if (payload->len) {
    out->payload = malloc(payload->len);
    if (out->payload) memcpy(out->payload, payload->data, payload->len);
  }
  out->payload_len = payload->len;
  if (!out->topic || (payload->len && !out->payload)) {
    wg_event_free(out);
    return WG_ERR_MEMORY;
  }
  return WG_OK;
}

static int queue_event(wg_client *c, const wg_frame_view *frame) {
  if (c->queue_len == c->queue_cap) {
    set_error(c, "event queue full; connection closed to preserve protocol ordering");
    shutdown(c->fd, SHUT_RDWR);
    close(c->fd);
    c->fd = -1;
    return WG_ERR_OVERFLOW;
  }
  size_t slot = (c->queue_head + c->queue_len) % c->queue_cap;
  int rc = event_from_frame(frame, &c->queue[slot].value);
  if (rc == WG_OK) c->queue_len++;
  return rc;
}

static int pop_event(wg_client *c, wg_event *out) {
  if (!c->queue_len) return 0;
  *out = c->queue[c->queue_head].value;
  memset(&c->queue[c->queue_head].value, 0, sizeof(wg_event));
  c->queue_head = (c->queue_head + 1) % c->queue_cap;
  c->queue_len--;
  return 1;
}

static int request(wg_client *c, uint8_t op, const uint8_t *fields, size_t fields_len,
                   wg_frame_view *response, uint8_t **response_buf) {
  if (!c) return WG_ERR_ARGUMENT;
  uint32_t id = ++c->next_request_id;
  int rc = send_request(c, op, id, fields, fields_len);
  if (rc != WG_OK) return rc;

  for (;;) {
    uint8_t *buf = NULL;
    size_t len = 0;
    rc = read_frame(c, c->timeout_ms, &buf, &len);
    if (rc != WG_OK) return rc;
    wg_frame_view frame;
    rc = parse_frame(buf, len, &frame);
    if (rc != WG_OK) { free(buf); return rc; }

    if (frame.kind == WG_KIND_EVENT) {
      rc = queue_event(c, &frame);
      free(buf);
      if (rc != WG_OK) return rc;
      continue;
    }

    if (frame.kind != WG_KIND_RESPONSE || frame.request_id != id || frame.op != op) {
      free(buf);
      set_error(c, "protocol error");
      if (c->fd >= 0) { shutdown(c->fd, SHUT_RDWR); close(c->fd); c->fd = -1; }
      return WG_ERR_PROTOCOL;
    }

    const wg_field_view *status = field(&frame, WG_F_STATUS);
    if (!status || status->len == 0) { free(buf); return WG_ERR_PROTOCOL; }
    if (!(status->len == 2 && memcmp(status->data, "ok", 2) == 0)) {
      const wg_field_view *err = field(&frame, WG_F_ERROR);
      if (err) {
        size_t n = err->len < WG_MAX_ERROR - 1 ? err->len : WG_MAX_ERROR - 1;
        memcpy(c->error, err->data, n); c->error[n] = '\0';
      } else set_error(c, "remote error");
      free(buf);
      return WG_ERR_REMOTE;
    }

    *response = frame;
    *response_buf = buf;
    return WG_OK;
  }
}

static int one_string_request(wg_client *c, uint8_t op, uint8_t tag, const char *value) {
  if (!c || !value) return WG_ERR_ARGUMENT;
  size_t n = strlen(value), len = 0;
  if (n > WG_MAX_FIELD) return WG_ERR_ARGUMENT;
  uint8_t *fields = malloc(5u + n);
  if (!fields) return WG_ERR_MEMORY;
  int rc = append_field(fields, 5u + n, &len, tag, value, n);
  wg_frame_view response; uint8_t *buf = NULL;
  if (rc == WG_OK) rc = request(c, op, fields, len, &response, &buf);
  free(buf); free(fields);
  return rc;
}

void wg_client_options_init(wg_client_options *options) {
  if (!options) return;
  options->timeout_ms = 5000;
  options->event_queue_capacity = WG_DEFAULT_EVENT_QUEUE;
  options->auth_token = NULL;
}

static int set_blocking(int fd, int blocking) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  if (blocking) flags &= ~O_NONBLOCK;
  else flags |= O_NONBLOCK;
  return fcntl(fd, F_SETFL, flags);
}

static int dial(const char *host, uint16_t port, uint32_t timeout_ms) {
  char service[16];
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  struct addrinfo hints; memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *res = NULL;
  if (getaddrinfo(host, service, &hints, &res) != 0) return -1;
  int fd = -1;
  for (struct addrinfo *it = res; it; it = it->ai_next) {
    fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
    if (fd < 0) continue;
    if (set_blocking(fd, 0) != 0) { close(fd); fd = -1; continue; }
    int connected = connect(fd, it->ai_addr, it->ai_addrlen);
    if (connected < 0 && errno == EINPROGRESS) {
      if (wait_fd(fd, POLLOUT, timeout_ms) != WG_OK) { close(fd); fd = -1; continue; }
      int soerr = 0; socklen_t sl = sizeof(soerr);
      if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) < 0 || soerr != 0) { close(fd); fd = -1; continue; }
      connected = 0;
    }
    if (connected == 0 && set_blocking(fd, 1) == 0) {
      int one = 1;
      (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
      (void)setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
      break;
    }
    close(fd); fd = -1;
  }
  freeaddrinfo(res);
  return fd;
}

int wg_connect_ex(const char *host, uint16_t port, const char *user_id,
                  const wg_client_options *options, wg_client **out_client,
                  char *error, size_t error_cap) {
  if (error && error_cap) error[0] = '\0';
  if (!host || !user_id || !out_client) return connect_fail(WG_ERR_ARGUMENT, error, error_cap);
  wg_client_options defaults; wg_client_options_init(&defaults);
  const wg_client_options *o = options ? options : &defaults;
  if (!o->event_queue_capacity || o->event_queue_capacity > 1000000u) return connect_fail(WG_ERR_ARGUMENT, error, error_cap);
  uint32_t timeout_ms = o->timeout_ms ? o->timeout_ms : 5000;
  int fd = dial(host, port, timeout_ms);
  if (fd < 0) return connect_fail(WG_ERR_IO, error, error_cap);
  wg_client *c = calloc(1, sizeof(*c));
  if (!c) { close(fd); return connect_fail(WG_ERR_MEMORY, error, error_cap); }
  c->fd = fd; c->timeout_ms = timeout_ms;
  c->queue_cap = o->event_queue_capacity;
  c->queue = calloc(c->queue_cap, sizeof(*c->queue));
  if (!c->queue) { close(fd); free(c); return connect_fail(WG_ERR_MEMORY, error, error_cap); }
  size_t n = strlen(user_id), token_len = o->auth_token ? strlen(o->auth_token) : 0, len = 0;
  size_t fields_cap = 5u + n + (o->auth_token ? 5u + token_len : 0u);
  uint8_t *fields = malloc(fields_cap);
  if (!fields) { wg_close(c); return connect_fail(WG_ERR_MEMORY, error, error_cap); }
  int rc = append_field(fields, fields_cap, &len, WG_F_USER_ID, user_id, n);
  if (rc == WG_OK && o->auth_token) rc = append_field(fields, fields_cap, &len, WG_F_AUTH_TOKEN, o->auth_token, token_len);
  wg_frame_view response; uint8_t *buf = NULL;
  if (rc == WG_OK) rc = request(c, WG_OP_HELLO, fields, len, &response, &buf);
  free(buf); free(fields);
  if (rc != WG_OK) {
    if (error && error_cap) snprintf(error, error_cap, "%s", c->error[0] ? c->error : wg_result_string(rc));
    wg_close(c);
    return rc;
  }
  *out_client = c;
  return WG_OK;
}

int wg_connect(const char *host, uint16_t port, const char *user_id,
               const wg_client_options *options, wg_client **out_client) {
  return wg_connect_ex(host, port, user_id, options, out_client, NULL, 0);
}

void wg_close(wg_client *c) {
  if (!c) return;
  if (c->fd >= 0) { shutdown(c->fd, SHUT_RDWR); close(c->fd); }
  for (size_t i = 0; i < c->queue_cap; i++) wg_event_free(&c->queue[i].value);
  free(c->queue); free(c);
}

int wg_subscribe(wg_client *c, const char *topic) { return one_string_request(c, WG_OP_SUBSCRIBE, WG_F_TOPIC, topic); }
int wg_unsubscribe(wg_client *c, const char *topic) { return one_string_request(c, WG_OP_UNSUBSCRIBE, WG_F_TOPIC, topic); }
int wg_ack(wg_client *c, const char *delivery_id) { return one_string_request(c, WG_OP_ACK, WG_F_DELIVERY_ID, delivery_id); }
int wg_set_presence(wg_client *c, const char *status) { return one_string_request(c, WG_OP_PRESENCE, WG_F_STATUS, status); }
int wg_join_room(wg_client *c, const char *room) { return one_string_request(c, WG_OP_JOIN_ROOM, WG_F_ROOM, room); }
int wg_leave_room(wg_client *c, const char *room) { return one_string_request(c, WG_OP_LEAVE_ROOM, WG_F_ROOM, room); }

int wg_publish(wg_client *c, const char *topic, const void *payload, size_t payload_len,
               const char *content_type, int durable, char *event_id, size_t event_id_cap) {
  if (!c || !topic || (!payload && payload_len)) return WG_ERR_ARGUMENT;
  if (!content_type) content_type = "application/octet-stream";
  size_t topic_len = strlen(topic), ct_len = strlen(content_type), cls_len = durable ? 7u : 9u;
  if (topic_len > WG_MAX_FIELD || ct_len > WG_MAX_FIELD || payload_len > WG_MAX_FIELD) return WG_ERR_ARGUMENT;
  size_t cap = 20u + topic_len + payload_len + ct_len + cls_len;
  if (cap > WG_MAX_FRAME) return WG_ERR_OVERFLOW;
  uint8_t *fields = malloc(cap); if (!fields) return WG_ERR_MEMORY;
  size_t len = 0; int rc = append_field(fields, cap, &len, WG_F_TOPIC, topic, topic_len);
  if (rc == WG_OK) rc = append_field(fields, cap, &len, WG_F_PAYLOAD, payload, payload_len);
  if (rc == WG_OK) rc = append_field(fields, cap, &len, WG_F_CONTENT_TYPE, content_type, ct_len);
  const char *cls = durable ? "durable" : "ephemeral";
  if (rc == WG_OK) rc = append_field(fields, cap, &len, WG_F_CLASS, cls, cls_len);
  wg_frame_view response; uint8_t *buf = NULL;
  if (rc == WG_OK) rc = request(c, WG_OP_PUBLISH, fields, len, &response, &buf);
  if (rc == WG_OK && event_id && event_id_cap) {
    const wg_field_view *f = field(&response, WG_F_EVENT_ID);
    if (f) { size_t n = f->len < event_id_cap-1 ? f->len : event_id_cap-1; memcpy(event_id, f->data, n); event_id[n] = '\0'; }
    else event_id[0] = '\0';
  }
  free(buf); free(fields); return rc;
}

int wg_ping(wg_client *c, char *server_version, size_t version_cap) {
  if (!c) return WG_ERR_ARGUMENT;
  wg_frame_view response; uint8_t *buf = NULL;
  int rc = request(c, WG_OP_PING, NULL, 0, &response, &buf);
  if (rc == WG_OK && server_version && version_cap) {
    const wg_field_view *f = field(&response, WG_F_SERVER_VERSION);
    if (f) { size_t n = f->len < version_cap-1 ? f->len : version_cap-1; memcpy(server_version, f->data, n); server_version[n] = '\0'; }
    else server_version[0] = '\0';
  }
  free(buf); return rc;
}

int wg_history(wg_client *c, const char *topic, const char *cursor, uint32_t limit,
              void *out, size_t out_cap, size_t *out_len, char *next_cursor, size_t next_cursor_cap) {
  if (!c || !topic || !out || !out_len || limit > 1000u) return WG_ERR_ARGUMENT;
  size_t topic_len = strlen(topic);
  size_t cursor_len = cursor ? strlen(cursor) : 0;
  char limit_buf[16];
  int limit_len = 0;
  if (limit) {
    limit_len = snprintf(limit_buf, sizeof(limit_buf), "%u", limit);
    if (limit_len <= 0 || (size_t)limit_len >= sizeof(limit_buf)) return WG_ERR_ARGUMENT;
  }
  if (topic_len > WG_MAX_FIELD || cursor_len > WG_MAX_FIELD) return WG_ERR_ARGUMENT;
  size_t cap = 5u + topic_len + (cursor ? 5u + cursor_len : 0u) + (limit ? 5u + (size_t)limit_len : 0u);
  uint8_t *fields = malloc(cap);
  if (!fields) return WG_ERR_MEMORY;
  size_t len = 0;
  int rc = append_field(fields, cap, &len, WG_F_TOPIC, topic, topic_len);
  if (rc == WG_OK && cursor) rc = append_field(fields, cap, &len, WG_F_CURSOR, cursor, cursor_len);
  if (rc == WG_OK && limit) rc = append_field(fields, cap, &len, WG_F_LIMIT, limit_buf, (size_t)limit_len);
  wg_frame_view response; uint8_t *buf = NULL;
  if (rc == WG_OK) rc = request(c, WG_OP_HISTORY, fields, len, &response, &buf);
  if (rc == WG_OK) {
    const wg_field_view *payload = field(&response, WG_F_PAYLOAD);
    if (!payload) rc = WG_ERR_PROTOCOL;
    else if (payload->len > out_cap) rc = WG_ERR_OVERFLOW;
    else {
      if (payload->len) memcpy(out, payload->data, payload->len);
      *out_len = payload->len;
      if (next_cursor && next_cursor_cap) {
        const wg_field_view *next = field(&response, WG_F_CURSOR);
        if (next) {
          size_t n = next->len < next_cursor_cap - 1 ? next->len : next_cursor_cap - 1;
          memcpy(next_cursor, next->data, n);
          next_cursor[n] = '\0';
        } else next_cursor[0] = '\0';
      }
    }
  }
  free(buf); free(fields);
  return rc;
}

int wg_poll(wg_client *c, uint32_t timeout_ms, wg_event *out_event) {
  if (!c || !out_event) return WG_ERR_ARGUMENT;
  if (pop_event(c, out_event)) return WG_OK;
  uint8_t *buf = NULL; size_t len = 0;
  int rc = read_frame(c, timeout_ms, &buf, &len);
  if (rc != WG_OK) return rc;
  wg_frame_view frame; rc = parse_frame(buf, len, &frame);
  if (rc == WG_OK && frame.kind == WG_KIND_EVENT) rc = event_from_frame(&frame, out_event);
  else if (rc == WG_OK) rc = WG_ERR_PROTOCOL;
  free(buf); return rc;
}

const char *wg_last_error(const wg_client *c) { return c ? c->error : "invalid client"; }
const char *wg_result_string(int result) {
  switch (result) {
    case WG_OK: return "ok";
    case WG_ERR_ARGUMENT: return "invalid argument";
    case WG_ERR_MEMORY: return "out of memory";
    case WG_ERR_IO: return "I/O error";
    case WG_ERR_PROTOCOL: return "protocol error";
    case WG_ERR_REMOTE: return "remote error";
    case WG_ERR_TIMEOUT: return "timeout";
    case WG_ERR_OVERFLOW: return "bounded queue/frame overflow";
    case WG_ERR_CLOSED: return "connection closed";
    default: return "unknown Wiregrid error";
  }
}
uint32_t wg_protocol_version(void) { return WG_PROTOCOL_VERSION; }
uint32_t wg_abi_major(void) { return WG_ABI_MAJOR; }
uint32_t wg_abi_minor(void) { return WG_ABI_MINOR; }
