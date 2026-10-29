#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef __ANDROID__
#include <linux/errqueue.h>
#include <linux/net_tstamp.h>
#endif

#define MAGIC 0x454e5848u /* HXNE */
#define VERSION 1u
#define LOG_MAGIC "HLXECH1\0"
#define LOG_VERSION 1u
#define CONTROL_SIZE 512
#define RCVBUF_BYTES (4 * 1024 * 1024)

#pragma pack(push, 1)
struct packet {
    uint32_t magic;
    uint16_t version;
    uint16_t flags;
    uint64_t sequence;
    uint64_t host_send_realtime_ns;
    uint64_t quest_recv_realtime_ns;
    uint64_t quest_echo_send_realtime_ns;
};

struct log_header {
    char magic[8];
    uint32_t version;
    uint32_t record_size;
    uint64_t reserved0;
    uint64_t reserved1;
};

struct host_record {
    uint64_t sequence;
    uint64_t host_send_realtime_ns;
    uint64_t host_tx_kernel_realtime_ns;
    uint64_t quest_recv_realtime_ns;
    uint64_t quest_echo_send_realtime_ns;
    uint64_t host_echo_recv_realtime_ns;
    int32_t send_result;
    uint32_t flags;
};
#pragma pack(pop)

enum {
    REC_ECHO = 1u << 0,
    REC_TX_TS = 1u << 1,
};

static uint64_t mono_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime monotonic");
        exit(2);
    }
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static uint64_t realtime_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        perror("clock_gettime realtime");
        exit(2);
    }
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static void sleep_until(uint64_t target_ns)
{
    struct timespec ts = {
        .tv_sec = (time_t)(target_ns / UINT64_C(1000000000)),
        .tv_nsec = (long)(target_ns % UINT64_C(1000000000)),
    };
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) != 0) {
        if (errno != EINTR) {
            perror("clock_nanosleep");
            exit(2);
        }
    }
}

static long parse_long(const char *name, const char *s, long lo, long hi)
{
    char *end = NULL;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno || !end || *end || v < lo || v > hi) {
        fprintf(stderr, "invalid %s: %s\n", name, s);
        exit(2);
    }
    return v;
}

static uint64_t timestamp_from_cmsg(struct msghdr *msg)
{
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(msg); cmsg; cmsg = CMSG_NXTHDR(msg, cmsg)) {
#ifdef SCM_TIMESTAMPNS
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_TIMESTAMPNS &&
            cmsg->cmsg_len >= CMSG_LEN(sizeof(struct timespec))) {
            struct timespec ts;
            memcpy(&ts, CMSG_DATA(cmsg), sizeof(ts));
            return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
        }
#endif
    }
    return 0;
}

#ifndef __ANDROID__
static void drain_tx_timestamps(int fd, struct host_record *records, uint64_t total)
{
    for (;;) {
        char data[256];
        char control[CONTROL_SIZE];
        struct iovec iov = {.iov_base = data, .iov_len = sizeof(data)};
        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control;
        msg.msg_controllen = sizeof(control);

        ssize_t n = recvmsg(fd, &msg, MSG_ERRQUEUE | MSG_DONTWAIT);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                return;
            return;
        }

        uint64_t tx_ns = 0;
        uint32_t id = UINT32_MAX;
        for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
#ifdef SCM_TIMESTAMPING
            if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_TIMESTAMPING &&
                cmsg->cmsg_len >= CMSG_LEN(3 * sizeof(struct timespec))) {
                struct timespec ts[3];
                memcpy(ts, CMSG_DATA(cmsg), sizeof(ts));
                for (int i = 0; i < 3; ++i) {
                    if (ts[i].tv_sec || ts[i].tv_nsec) {
                        tx_ns = (uint64_t)ts[i].tv_sec * UINT64_C(1000000000) + (uint64_t)ts[i].tv_nsec;
                        break;
                    }
                }
            }
#endif
            if ((cmsg->cmsg_level == SOL_IP && cmsg->cmsg_type == IP_RECVERR) ||
                (cmsg->cmsg_level == SOL_IPV6 && cmsg->cmsg_type == IPV6_RECVERR)) {
                if (cmsg->cmsg_len >= CMSG_LEN(sizeof(struct sock_extended_err))) {
                    struct sock_extended_err ee;
                    memcpy(&ee, CMSG_DATA(cmsg), sizeof(ee));
                    if (ee.ee_origin == SO_EE_ORIGIN_TIMESTAMPING)
                        id = ee.ee_data;
                }
            }
        }
        if (tx_ns && id < total) {
            records[id].host_tx_kernel_realtime_ns = tx_ns;
            records[id].flags |= REC_TX_TS;
        }
    }
}
#endif

static int host_main(int argc, char **argv)
{
    if (argc != 8) {
        fprintf(stderr, "usage: %s host <ip> <port> <duration_s> <hz> <payload_bytes> <output.bin>\n", argv[0]);
        return 2;
    }
    const char *ip = argv[2];
    long port = parse_long("port", argv[3], 1024, 65535);
    long duration_s = parse_long("duration_s", argv[4], 1, 3600);
    long hz = parse_long("hz", argv[5], 1, 1000);
    long payload_bytes = parse_long("payload_bytes", argv[6], (long)sizeof(struct packet), 65000);
    const char *output = argv[7];
    uint64_t total = (uint64_t)duration_s * (uint64_t)hz;

    struct host_record *records = calloc((size_t)total, sizeof(*records));
    uint8_t *buf = calloc(1, (size_t)payload_bytes);
    if (!records || !buf) {
        perror("calloc");
        return 2;
    }
    for (uint64_t i = 0; i < total; ++i)
        records[i].sequence = i;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 2;
    }
    int one = 1;
    int rx_timestamp_supported = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPNS, &one, sizeof(one)) == 0;
    int rcvbuf = RCVBUF_BYTES;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    int tx_timestamp_supported = 0;
#ifndef __ANDROID__
    int ts_flags = SOF_TIMESTAMPING_TX_SOFTWARE | SOF_TIMESTAMPING_SOFTWARE | SOF_TIMESTAMPING_OPT_ID;
    if (setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPING, &ts_flags, sizeof(ts_flags)) == 0) {
        int errq = 1;
        (void)setsockopt(fd, SOL_IP, IP_RECVERR, &errq, sizeof(errq));
        tx_timestamp_supported = 1;
    }
#endif

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &dst.sin_addr) != 1) {
        fprintf(stderr, "invalid destination IPv4: %s\n", ip);
        return 2;
    }

    uint64_t period_ns = UINT64_C(1000000000) / (uint64_t)hz;
    uint64_t start_ns = mono_ns() + UINT64_C(200000000);
    uint64_t send_errors = 0;
    uint64_t echoes = 0;
    uint64_t echo_duplicates = 0;
    uint64_t echo_out_of_range = 0;
    uint64_t echo_timestamp_missing = 0;

    for (uint64_t seq = 0; seq < total; ++seq) {
        uint64_t target = start_ns + seq * period_ns;
        if (mono_ns() < target)
            sleep_until(target);

        struct packet p;
        memset(&p, 0, sizeof(p));
        p.magic = MAGIC;
        p.version = VERSION;
        p.sequence = seq;
        p.host_send_realtime_ns = realtime_ns();
        memcpy(buf, &p, sizeof(p));
        records[seq].host_send_realtime_ns = p.host_send_realtime_ns;
        ssize_t n = sendto(fd, buf, (size_t)payload_bytes, 0, (struct sockaddr *)&dst, sizeof(dst));
        if (n != payload_bytes) {
            records[seq].send_result = n < 0 ? -errno : (int32_t)n;
            ++send_errors;
        }

#ifndef __ANDROID__
        if (tx_timestamp_supported)
            drain_tx_timestamps(fd, records, total);
#endif

        for (;;) {
            struct pollfd pfd = {.fd = fd, .events = POLLIN};
            int pr = poll(&pfd, 1, 0);
            if (pr <= 0 || !(pfd.revents & POLLIN))
                break;

            char control[CONTROL_SIZE];
            struct iovec iov = {.iov_base = buf, .iov_len = (size_t)payload_bytes};
            struct msghdr msg;
            memset(&msg, 0, sizeof(msg));
            msg.msg_iov = &iov;
            msg.msg_iovlen = 1;
            msg.msg_control = control;
            msg.msg_controllen = sizeof(control);
            ssize_t rn = recvmsg(fd, &msg, 0);
            if (rn < (ssize_t)sizeof(struct packet))
                continue;
            struct packet ep;
            memcpy(&ep, buf, sizeof(ep));
            if (ep.magic != MAGIC || ep.version != VERSION || ep.sequence >= total) {
                ++echo_out_of_range;
                continue;
            }
            struct host_record *r = &records[ep.sequence];
            if (r->flags & REC_ECHO) {
                ++echo_duplicates;
                continue;
            }
            r->quest_recv_realtime_ns = ep.quest_recv_realtime_ns;
            r->quest_echo_send_realtime_ns = ep.quest_echo_send_realtime_ns;
            r->host_echo_recv_realtime_ns = timestamp_from_cmsg(&msg);
            if (!r->host_echo_recv_realtime_ns) {
                ++echo_timestamp_missing;
                r->host_echo_recv_realtime_ns = realtime_ns();
            }
            r->flags |= REC_ECHO;
            ++echoes;
        }
    }

    uint64_t drain_deadline = mono_ns() + UINT64_C(2000000000);
    while (mono_ns() < drain_deadline && echoes < total) {
#ifndef __ANDROID__
        if (tx_timestamp_supported)
            drain_tx_timestamps(fd, records, total);
#endif
        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        int pr = poll(&pfd, 1, 20);
        if (pr <= 0 || !(pfd.revents & POLLIN))
            continue;
        char control[CONTROL_SIZE];
        struct iovec iov = {.iov_base = buf, .iov_len = (size_t)payload_bytes};
        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control;
        msg.msg_controllen = sizeof(control);
        ssize_t rn = recvmsg(fd, &msg, 0);
        if (rn < (ssize_t)sizeof(struct packet))
            continue;
        struct packet ep;
        memcpy(&ep, buf, sizeof(ep));
        if (ep.magic != MAGIC || ep.version != VERSION || ep.sequence >= total) {
            ++echo_out_of_range;
            continue;
        }
        struct host_record *r = &records[ep.sequence];
        if (r->flags & REC_ECHO) {
            ++echo_duplicates;
            continue;
        }
        r->quest_recv_realtime_ns = ep.quest_recv_realtime_ns;
        r->quest_echo_send_realtime_ns = ep.quest_echo_send_realtime_ns;
        r->host_echo_recv_realtime_ns = timestamp_from_cmsg(&msg);
        if (!r->host_echo_recv_realtime_ns) {
            ++echo_timestamp_missing;
            r->host_echo_recv_realtime_ns = realtime_ns();
        }
        r->flags |= REC_ECHO;
        ++echoes;
    }
#ifndef __ANDROID__
    if (tx_timestamp_supported)
        drain_tx_timestamps(fd, records, total);
#endif

    FILE *f = fopen(output, "wb");
    if (!f) {
        perror("fopen output");
        return 2;
    }
    struct log_header lh;
    memset(&lh, 0, sizeof(lh));
    memcpy(lh.magic, LOG_MAGIC, sizeof(lh.magic));
    lh.version = LOG_VERSION;
    lh.record_size = sizeof(struct host_record);
    if (fwrite(&lh, sizeof(lh), 1, f) != 1 || fwrite(records, sizeof(*records), (size_t)total, f) != total) {
        perror("fwrite log");
        fclose(f);
        return 2;
    }
    int flush_ok = fflush(f);
    int close_ok = fclose(f);

    uint64_t tx_ts_count = 0;
    for (uint64_t i = 0; i < total; ++i)
        if (records[i].flags & REC_TX_TS)
            ++tx_ts_count;

    printf("role=host\n");
    printf("destination=%s:%ld\n", ip, port);
    printf("duration_s=%ld\n", duration_s);
    printf("hz=%ld\n", hz);
    printf("payload_bytes=%ld\n", payload_bytes);
    printf("total_packets=%" PRIu64 "\n", total);
    printf("send_errors=%" PRIu64 "\n", send_errors);
    printf("echoes_received=%" PRIu64 "\n", echoes);
    printf("echo_duplicates=%" PRIu64 "\n", echo_duplicates);
    printf("echo_out_of_range=%" PRIu64 "\n", echo_out_of_range);
    printf("echo_rx_kernel_timestamp_supported=%s\n", rx_timestamp_supported ? "true" : "false");
    printf("echo_rx_timestamp_missing=%" PRIu64 "\n", echo_timestamp_missing);
    printf("tx_kernel_timestamp_supported=%s\n", tx_timestamp_supported ? "true" : "false");
    printf("tx_kernel_timestamp_count=%" PRIu64 "\n", tx_ts_count);
    printf("log_flush_ok=%s\n", (flush_ok == 0 && close_ok == 0) ? "true" : "false");

    free(buf);
    free(records);
    close(fd);
    return (send_errors == 0 && flush_ok == 0 && close_ok == 0) ? 0 : 3;
}

static int quest_main(int argc, char **argv)
{
    if (argc != 6) {
        fprintf(stderr, "usage: %s quest <port> <duration_s> <payload_bytes> <status.txt>\n", argv[0]);
        return 2;
    }
    long port = parse_long("port", argv[2], 1024, 65535);
    long duration_s = parse_long("duration_s", argv[3], 1, 3600);
    long payload_bytes = parse_long("payload_bytes", argv[4], (long)sizeof(struct packet), 65000);
    const char *status_path = argv[5];

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 2;
    }
    int one = 1;
    int ts_supported = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPNS, &one, sizeof(one)) == 0;
    int rcvbuf = RCVBUF_BYTES;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    struct timeval tv = {.tv_sec = 0, .tv_usec = 200000};
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        return 2;
    }

    uint8_t *buf = malloc((size_t)payload_bytes);
    if (!buf) {
        perror("malloc");
        return 2;
    }
    uint64_t valid = 0, invalid = 0, send_errors = 0, ts_missing = 0;
    uint64_t end_ns = mono_ns() + (uint64_t)duration_s * UINT64_C(1000000000);

    while (mono_ns() < end_ns) {
        char control[CONTROL_SIZE];
        struct sockaddr_in peer;
        socklen_t peer_len = sizeof(peer);
        struct iovec iov = {.iov_base = buf, .iov_len = (size_t)payload_bytes};
        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
        msg.msg_name = &peer;
        msg.msg_namelen = peer_len;
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control;
        msg.msg_controllen = sizeof(control);
        ssize_t n = recvmsg(fd, &msg, 0);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
                continue;
            perror("recvmsg");
            break;
        }
        if (n < (ssize_t)sizeof(struct packet)) {
            ++invalid;
            continue;
        }
        struct packet p;
        memcpy(&p, buf, sizeof(p));
        if (p.magic != MAGIC || p.version != VERSION) {
            ++invalid;
            continue;
        }
        p.quest_recv_realtime_ns = timestamp_from_cmsg(&msg);
        if (!p.quest_recv_realtime_ns) {
            ++ts_missing;
            p.quest_recv_realtime_ns = realtime_ns();
        }
        p.quest_echo_send_realtime_ns = realtime_ns();
        memcpy(buf, &p, sizeof(p));
        ssize_t sn = sendto(fd, buf, (size_t)payload_bytes, 0, (struct sockaddr *)&peer, msg.msg_namelen);
        if (sn != payload_bytes)
            ++send_errors;
        ++valid;
    }

    FILE *sf = fopen(status_path, "w");
    if (!sf) {
        perror("fopen status");
        return 2;
    }
    fprintf(sf, "role=quest_echo\n");
    fprintf(sf, "duration_s=%ld\n", duration_s);
    fprintf(sf, "payload_bytes=%ld\n", payload_bytes);
    fprintf(sf, "valid_packets=%" PRIu64 "\n", valid);
    fprintf(sf, "invalid_packets=%" PRIu64 "\n", invalid);
    fprintf(sf, "echo_send_errors=%" PRIu64 "\n", send_errors);
    fprintf(sf, "rx_kernel_timestamp_supported=%s\n", ts_supported ? "true" : "false");
    fprintf(sf, "rx_timestamp_missing=%" PRIu64 "\n", ts_missing);
    fclose(sf);
    free(buf);
    close(fd);
    return send_errors == 0 ? 0 : 3;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <host|quest> ...\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "host") == 0)
        return host_main(argc, argv);
    if (strcmp(argv[1], "quest") == 0)
        return quest_main(argc, argv);
    fprintf(stderr, "unknown mode: %s\n", argv[1]);
    return 2;
}
