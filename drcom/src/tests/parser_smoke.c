#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../configparse.h"

static int write_file(const char *path, const char *content);
static int expect_true(const char *name, int condition);
static int expect_string(const char *name, const char *actual, const char *expected);
static void set_mode_value(const char *value);
static int test_valid_dhcp_config(void);
static int test_rejects_overlong_value(void);
static int test_rejects_invalid_auth_version(void);
static int test_accepts_legacy_quoted_config(void);

static int write_file(const char *path, const char *content) {
    FILE *file = fopen(path, "w");
    if (file == NULL) {
        fprintf(stderr, "failed to create %s\n", path);
        return 1;
    }

    if (fputs(content, file) == EOF) {
        fclose(file);
        fprintf(stderr, "failed to write %s\n", path);
        return 1;
    }

    fclose(file);
    return 0;
}

static int expect_true(const char *name, int condition) {
    if (!condition) {
        fprintf(stderr, "assertion failed: %s\n", name);
        return 1;
    }
    return 0;
}

static int expect_string(const char *name, const char *actual, const char *expected) {
    if ((actual == NULL && expected != NULL) || (actual != NULL && expected == NULL)) {
        fprintf(stderr, "assertion failed: %s\n", name);
        return 1;
    }

    if (actual != NULL && strcmp(actual, expected) != 0) {
        fprintf(stderr, "assertion failed: %s (got=%s expected=%s)\n", name, actual, expected);
        return 1;
    }

    return 0;
}

static void set_mode_value(const char *value) {
    memset(mode, 0, sizeof(mode));
    snprintf(mode, sizeof(mode), "%s", value);
}

static int test_valid_dhcp_config(void) {
    const char *path = "tests/parser_valid.conf";
    const char *content =
        "# comment\n"
        "\n"
        "server = '10.100.61.3'\n"
        "username = 'student'\n"
        "password = 'secret-pass'\n"
        "keepalive1_mod = True\n"
        "host_name = 'fuyumi'\n"
        "host_os = 'Windows 10'\n"
        "host_ip = '172.18.27.227'\n"
        "PRIMARY_DNS = '10.10.10.10'\n"
        "dhcp_server = '0.0.0.0'\n"
        "CONTROLCHECKSTATUS = '\\x20'\n"
        "ADAPTERNUM = '\\x05'\n"
        "IPDOG = '\\x01'\n"
        "AUTH_VERSION = '\\x2c\\x00'\n"
        "KEEP_ALIVE_VERSION = '\\xdc\\x02'\n"
        "mac = B0:25:AA:85:10:14\n"
        "ror_version = False\n";

    memset(bind_ip, 0, sizeof(bind_ip));
    set_mode_value("dhcp");

    if (write_file(path, content) != 0) {
        return 1;
    }

    if (expect_true("valid config parses", config_parse((char *)path) == 0) != 0) {
        remove(path);
        return 1;
    }

    if (expect_string("server parsed", drcom_config.server, "10.100.61.3") != 0 ||
        expect_string("username parsed", drcom_config.username, "student") != 0 ||
        expect_string("host_os keeps spaces", drcom_config.host_os, "Windows 10") != 0 ||
        expect_true("keepalive1_mod persists", drcom_config.keepalive1_mod == 1) != 0 ||
        expect_true("ror_version false", drcom_config.ror_version == 0) != 0 ||
        expect_true("mac parsed", drcom_config.mac[0] == 0xB0 && drcom_config.mac[5] == 0x14) != 0) {
        remove(path);
        return 1;
    }

    remove(path);
    return 0;
}

static int test_rejects_overlong_value(void) {
    const char *path = "tests/parser_overlong.conf";
    const char *content =
        "server = '10.100.61.3'\n"
        "username = 'this_username_is_far_longer_than_thirty_six_characters_total'\n";

    set_mode_value("dhcp");

    if (write_file(path, content) != 0) {
        return 1;
    }

    if (expect_true("overlong username rejected", config_parse((char *)path) != 0) != 0) {
        remove(path);
        return 1;
    }

    remove(path);
    return 0;
}

static int test_rejects_invalid_auth_version(void) {
    const char *path = "tests/parser_invalid_auth.conf";
    const char *content =
        "server = '10.100.61.3'\n"
        "username = 'student'\n"
        "password = 'secret'\n"
        "AUTH_VERSION = '\\x2c'\n";

    set_mode_value("dhcp");

    if (write_file(path, content) != 0) {
        return 1;
    }

    if (expect_true("short auth version rejected", config_parse((char *)path) != 0) != 0) {
        remove(path);
        return 1;
    }

    remove(path);
    return 0;
}

static int test_accepts_legacy_quoted_config(void) {
    const char *path = "tests/parser_legacy.conf";
    const char *content =
        "server='10.100.61.3'\n"
        "username='student'\n"
        "password='secret'\n"
        "PRIMARY_DNS='10.10.10.10'\n"
        "SECONDARY_DNS='8.8.8.8'\n"
        "host_name='fuyumi'\n"
        "host_os='Windows 10'\n"
        "mac='DE:F3:75:89:E1:20'\n"
        "host_ip='172.18.27.227'\n"
        "dhcp_server='0.0.0.0'\n"
        "CONTROLCHECKSTATUS='\\x20'\n"
        "ADAPTERNUM='\\x05'\n"
        "IPDOG='\\x01'\n"
        "AUTH_VERSION='\\x2c\\x00'\n"
        "KEEP_ALIVE_VERSION='\\xdc\\x02'\n"
        "ror_version=0\n"
        "keepalive1_mod=1\n"
        "bind_ip='0.0.0.0'\n"
        "log='/tmp/drcom.log'\n"
        "eternal=1\n";

    memset(bind_ip, 0, sizeof(bind_ip));
    free(log_path);
    log_path = NULL;
    logging_flag = 0;
    eternal_flag = 0;
    set_mode_value("dhcp");

    if (write_file(path, content) != 0) {
        return 1;
    }

    if (expect_true("legacy config parses", config_parse((char *)path) == 0) != 0) {
        remove(path);
        return 1;
    }

    if (expect_string("legacy bind_ip parsed", bind_ip, "0.0.0.0") != 0 ||
        expect_true("legacy log enables logging", logging_flag == 1) != 0 ||
        expect_true("legacy eternal parsed", eternal_flag == 1) != 0 ||
        expect_true("legacy mac parsed", drcom_config.mac[0] == 0xDE && drcom_config.mac[5] == 0x20) != 0) {
        remove(path);
        return 1;
    }

    remove(path);
    return 0;
}

int main(void) {
    if (test_valid_dhcp_config() != 0) {
        return 1;
    }
    if (test_rejects_overlong_value() != 0) {
        return 1;
    }
    if (test_rejects_invalid_auth_version() != 0) {
        return 1;
    }
    if (test_accepts_legacy_quoted_config() != 0) {
        return 1;
    }

    printf("parser smoke tests passed\n");
    return 0;
}
