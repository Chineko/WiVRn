#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define HELIX_MAGIC 0x544e5848u /* HXNT, little-endian bytes */
#define HELIX_VERSION 1u
#define RX_MAGIC "HLXRX1\0"
#define TX_MAGIC "HLXTX1\0"
#define LOG_VERSION 1u
#define CONTROL_SIZE 256
#define DEFAULT_RCVBUF (16 * 1024 * 1024)

#pragma pack(push, 1)
struct packet_header {
    uint32_t magic;
    uint16_t version;
    uint16_t flags;
    uint64_t sequence;
    uint64_t burst;
    uint64_t send_realtime_ns;
    uint32_t packet_index;
    uint32_t packets_per_burst;
};

struct log_file_header {
    char magic[8];
    uint32_t version;
    uint32_t record_size;
    uint64_t reserved0;
    uint64_t reserved1;
};

struct tx_record {
    uint64_t sequence;
    uint64_t burst;
    uint64_t send_realtime_ns;
    uint32_t packet_index;
    int32_t send_result;
};

struct rx_record {
    uint64_t sequence;
    uint64_t burst;
    uint64_t send_realtime_ns;
    uint64_t recv_realtime_ns;
    uint32_t packet_index;
    uint32_t kernel_drops;
};
#pragma pack(pop)

static uint64_t mono_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(2);
    }
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static uint64_t realtime_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        perror("clock_gettime realtime");
        exit(2);
    }
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static void sleep_until(uint64_t target_ns) {
    struct timespec ts;
    ts.tv_sec = (time_t)(target_ns / UINT64_C(1000000000));
    ts.tv_nsec = (long)(target_ns % UINT64_C(1000000000));
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) != 0) {
        if (errno == EINTR)
            continue;
        perror("clock_nanosleep");
        exit(2);
    }
}

static long parse_long(const char *name, const char *s, long minv, long maxv) {
    char *end = NULL;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno || !end || *end || v < minv || v > maxv) {
        fprintf(stderr, "invalid %s: %s\n", name, s);
        exit(2);
    }
    return v;
}

static void fill_payload(uint8_t *buf, size_t len) {
    uint32_t x = 0x9e3779b9u;
    for (size_t i = sizeof(struct packet_header); i < len; ++i) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        buf[i] = (uint8_t)x;
    }
}

static int sender_main(int argc, char **argv) {
    if (argc != 10) {
        fprintf(stderr, "usage: %s send <ip> <port> <duration_s> <hz> <packets_per_burst> <spacing_us> <payload_bytes> <output.bin>\n", argv[0]);
        return 2;
    }

    const char *ip = argv[2];
    long port = parse_long("port", argv[3], 1024, 65535);
    long duration_s = parse_long("duration_s", argv[4], 1, 3600);
    long hz = parse_long("hz", argv[5], 1, 1000);
    long ppb = parse_long("packets_per_burst", argv[6], 1, 10000);
    long spacing_us = parse_long("spacing_us", argv[7], 1, 1000000);
    long payload_bytes = parse_long("payload_bytes", argv[8], (long)sizeof(struct packet_header), 65000);
    const char *output = argv[9];

    FILE *logf = fopen(output, "wb");
    if (!logf) {
        perror("fopen sender log");
        return 2;
    }
    static char tx_filebuf[1024 * 1024];
    if (setvbuf(logf, tx_filebuf, _IOFBF, sizeof(tx_filebuf)) != 0) {
        perror("setvbuf sender log");
        fclose(logf);
        return 2;
    }
    struct log_file_header lfh;
    memset(&lfh, 0, sizeof(lfh));
    memcpy(lfh.magic, TX_MAGIC, sizeof(lfh.magic));
    lfh.version = LOG_VERSION;
    lfh.record_size = sizeof(struct tx_record);
    if (fwrite(&lfh, sizeof(lfh), 1, logf) != 1) {
        perror("fwrite sender header");
        fclose(logf);
        return 2;
    }

    uint64_t period_ns = UINT64_C(1000000000) / (uint64_t)hz;
    uint64_t spacing_ns = (uint64_t)spacing_us * UINT64_C(1000);
    uint64_t occupied_ns = (uint64_t)(ppb - 1) * spacing_ns;
    if (occupied_ns >= period_ns) {
        fprintf(stderr, "packets_per_burst * spacing exceeds burst period: occupied=%" PRIu64 " ns period=%" PRIu64 " ns\n",
                occupied_ns, period_ns);
        fclose(logf);
        return 2;
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        fclose(logf);
        return 2;
    }

    int sndbuf = DEFAULT_RCVBUF;
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &dst.sin_addr) != 1) {
        fprintf(stderr, "invalid destination IPv4: %s\n", ip);
        close(fd);
        fclose(logf);
        return 2;
    }

    uint8_t *buf = malloc((size_t)payload_bytes);
    if (!buf) {
        perror("malloc");
        close(fd);
        fclose(logf);
        return 2;
    }
    memset(buf, 0, (size_t)payload_bytes);
    fill_payload(buf, (size_t)payload_bytes);

    uint64_t total_bursts = (uint64_t)duration_s * (uint64_t)hz;
    uint64_t total_packets = total_bursts * (uint64_t)ppb;
    uint64_t sequence = 0;
    uint64_t send_errors = 0;
    uint64_t short_sends = 0;
    uint64_t late_slots = 0;
    uint64_t max_late_ns = 0;

    uint64_t start_ns = mono_ns() + UINT64_C(200000000);
    for (uint64_t burst = 0; burst < total_bursts; ++burst) {
        uint64_t burst_start = start_ns + burst * period_ns;
        for (uint32_t i = 0; i < (uint32_t)ppb; ++i, ++sequence) {
            uint64_t target_ns = burst_start + (uint64_t)i * spacing_ns;
            uint64_t now = mono_ns();
            if (now < target_ns) {
                sleep_until(target_ns);
            } else {
                uint64_t late = now - target_ns;
                if (late > UINT64_C(100000))
                    ++late_slots;
                if (late > max_late_ns)
                    max_late_ns = late;
            }

            struct packet_header h;
            h.magic = HELIX_MAGIC;
            h.version = HELIX_VERSION;
            h.flags = 0;
            h.sequence = sequence;
            h.burst = burst;
            h.send_realtime_ns = realtime_ns();
            h.packet_index = i;
            h.packets_per_burst = (uint32_t)ppb;
            memcpy(buf, &h, sizeof(h));

            ssize_t n = sendto(fd, buf, (size_t)payload_bytes, 0, (struct sockaddr *)&dst, sizeof(dst));
            int send_result = 0;
            if (n < 0) {
                ++send_errors;
                send_result = -errno;
            } else if (n != payload_bytes) {
                ++short_sends;
                send_result = (int)n;
            }

            struct tx_record tr;
            tr.sequence = sequence;
            tr.burst = burst;
            tr.send_realtime_ns = h.send_realtime_ns;
            tr.packet_index = i;
            tr.send_result = send_result;
            if (fwrite(&tr, sizeof(tr), 1, logf) != 1) {
                perror("fwrite sender record");
                free(buf);
                close(fd);
                fclose(logf);
                return 2;
            }
        }
    }

    uint64_t finish_ns = mono_ns();
    int log_flush_ok = fflush(logf);
    int log_close_ok = fclose(logf);
    printf("role=sender\n");
    printf("destination=%s:%ld\n", ip, port);
    printf("duration_s=%ld\n", duration_s);
    printf("hz=%ld\n", hz);
    printf("packets_per_burst=%ld\n", ppb);
    printf("spacing_us=%ld\n", spacing_us);
    printf("payload_bytes=%ld\n", payload_bytes);
    printf("total_bursts=%" PRIu64 "\n", total_bursts);
    printf("total_packets=%" PRIu64 "\n", total_packets);
    printf("send_errors=%" PRIu64 "\n", send_errors);
    printf("short_sends=%" PRIu64 "\n", short_sends);
    printf("late_slots_over_100us=%" PRIu64 "\n", late_slots);
    printf("max_slot_late_us=%.3f\n", (double)max_late_ns / 1000.0);
    printf("sender_start_mono_ns=%" PRIu64 "\n", start_ns);
    printf("sender_finish_mono_ns=%" PRIu64 "\n", finish_ns);
    printf("log_flush_ok=%s\n", (log_flush_ok == 0 && log_close_ok == 0) ? "true" : "false");

    free(buf);
    close(fd);
    return (send_errors == 0 && short_sends == 0 && log_flush_ok == 0 && log_close_ok == 0) ? 0 : 3;
}

static int receiver_main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: %s recv <port> <duration_s> <payload_bytes> <output.bin>\n", argv[0]);
        return 2;
    }

    long port = parse_long("port", argv[2], 1024, 65535);
    long duration_s = parse_long("duration_s", argv[3], 1, 3600);
    long payload_bytes = parse_long("payload_bytes", argv[4], (long)sizeof(struct packet_header), 65000);
    const char *output = argv[5];

    FILE *f = fopen(output, "wb");
    if (!f) {
        perror("fopen");
        return 2;
    }
    static char filebuf[1024 * 1024];
    if (setvbuf(f, filebuf, _IOFBF, sizeof(filebuf)) != 0) {
        perror("setvbuf");
        fclose(f);
        return 2;
    }

    struct log_file_header fh;
    memset(&fh, 0, sizeof(fh));
    memcpy(fh.magic, RX_MAGIC, sizeof(fh.magic));
    fh.version = LOG_VERSION;
    fh.record_size = sizeof(struct rx_record);
    if (fwrite(&fh, sizeof(fh), 1, f) != 1) {
        perror("fwrite");
        fclose(f);
        return 2;
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        fclose(f);
        return 2;
    }

    int one = 1;
    int rxq_ovfl_supported = 0;
    int timestamp_supported = 0;
#ifdef SO_RXQ_OVFL
    if (setsockopt(fd, SOL_SOCKET, SO_RXQ_OVFL, &one, sizeof(one)) == 0)
        rxq_ovfl_supported = 1;
    else
        fprintf(stderr, "warning: SO_RXQ_OVFL unavailable: %s\n", strerror(errno));
#endif
#ifdef SO_TIMESTAMPNS
    if (setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPNS, &one, sizeof(one)) == 0)
        timestamp_supported = 1;
    else
        fprintf(stderr, "warning: SO_TIMESTAMPNS unavailable: %s\n", strerror(errno));
#endif
    int rcvbuf = DEFAULT_RCVBUF;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf)) != 0)
        fprintf(stderr, "warning: SO_RCVBUF request failed: %s\n", strerror(errno));
    socklen_t optlen = sizeof(rcvbuf);
    if (getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, &optlen) != 0)
        rcvbuf = -1;

    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 200000;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) {
        perror("setsockopt SO_RCVTIMEO");
        close(fd);
        fclose(f);
        return 2;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        close(fd);
        fclose(f);
        return 2;
    }

    uint8_t *buf = malloc((size_t)payload_bytes + 256);
    if (!buf) {
        perror("malloc");
        close(fd);
        fclose(f);
        return 2;
    }

    uint64_t start_ns = mono_ns();
    uint64_t end_ns = start_ns + (uint64_t)duration_s * UINT64_C(1000000000);
    uint64_t valid = 0, invalid = 0, truncated = 0, timestamp_missing = 0;
    uint32_t max_kernel_drops = 0;

    while (mono_ns() < end_ns) {
        struct iovec iov;
        iov.iov_base = buf;
        iov.iov_len = (size_t)payload_bytes + 256;

        char control[CONTROL_SIZE];
        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
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
        if (msg.msg_flags & MSG_TRUNC)
            ++truncated;
        if ((size_t)n < sizeof(struct packet_header)) {
            ++invalid;
            continue;
        }

        struct packet_header h;
        memcpy(&h, buf, sizeof(h));
        if (h.magic != HELIX_MAGIC || h.version != HELIX_VERSION) {
            ++invalid;
            continue;
        }

        uint32_t drops = max_kernel_drops;
        uint64_t recv_ns = 0;
        for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
#ifdef SO_RXQ_OVFL
            if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SO_RXQ_OVFL &&
                cmsg->cmsg_len >= CMSG_LEN(sizeof(uint32_t))) {
                memcpy(&drops, CMSG_DATA(cmsg), sizeof(drops));
                if (drops > max_kernel_drops)
                    max_kernel_drops = drops;
            }
#endif
#ifdef SCM_TIMESTAMPNS
            if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_TIMESTAMPNS &&
                cmsg->cmsg_len >= CMSG_LEN(sizeof(struct timespec))) {
                struct timespec ts;
                memcpy(&ts, CMSG_DATA(cmsg), sizeof(ts));
                recv_ns = (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
            }
#endif
        }
        if (recv_ns == 0)
            ++timestamp_missing;

        struct rx_record r;
        r.sequence = h.sequence;
        r.burst = h.burst;
        r.send_realtime_ns = h.send_realtime_ns;
        r.recv_realtime_ns = recv_ns;
        r.packet_index = h.packet_index;
        r.kernel_drops = drops;
        if (fwrite(&r, sizeof(r), 1, f) != 1) {
            perror("fwrite");
            free(buf);
            close(fd);
            fclose(f);
            return 2;
        }
        ++valid;
    }

    int flush_ok = fflush(f);
    int close_ok = fclose(f);
    uint64_t finish_ns = mono_ns();

    printf("role=receiver\n");
    printf("port=%ld\n", port);
    printf("duration_s=%ld\n", duration_s);
    printf("payload_bytes=%ld\n", payload_bytes);
    printf("valid_packets=%" PRIu64 "\n", valid);
    printf("invalid_packets=%" PRIu64 "\n", invalid);
    printf("truncated_packets=%" PRIu64 "\n", truncated);
    printf("socket_kernel_drops=%" PRIu32 "\n", max_kernel_drops);
    printf("rxq_ovfl_supported=%s\n", rxq_ovfl_supported ? "true" : "false");
    printf("kernel_timestamp_supported=%s\n", timestamp_supported ? "true" : "false");
    printf("kernel_timestamp_missing=%" PRIu64 "\n", timestamp_missing);
    printf("effective_so_rcvbuf_bytes=%d\n", rcvbuf);
    printf("receiver_start_mono_ns=%" PRIu64 "\n", start_ns);
    printf("receiver_finish_mono_ns=%" PRIu64 "\n", finish_ns);
    printf("log_flush_ok=%s\n", (flush_ok == 0 && close_ok == 0) ? "true" : "false");

    free(buf);
    close(fd);
    return (flush_ok == 0 && close_ok == 0) ? 0 : 3;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <send|recv> ...\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "send") == 0)
        return sender_main(argc, argv);
    if (strcmp(argv[1], "recv") == 0)
        return receiver_main(argc, argv);
    fprintf(stderr, "unknown mode: %s\n", argv[1]);
    return 2;
}
