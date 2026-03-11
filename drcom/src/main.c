#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "auth.h"
#include "configparse.h"

#ifdef linux
#include <errno.h>
#include <limits.h>
#include "daemon.h"
#include "eapol.h"
#include "libs/common.h"
#endif

#define VERSION "1.6.2"

void print_help(int exval);
int try_smart_eaplogin(void);

static const char default_bind_ip[20] = "0.0.0.0";

static int copy_option_value(char *dest, size_t dest_size, const char *source, const char *option_name);
static char *duplicate_path_value(const char *path, const char *option_name);
static int replace_dynamic_string(char **target, char *replacement);
static void cleanup_paths(char **file_path_ref);

static int copy_option_value(char *dest, size_t dest_size, const char *source, const char *option_name) {
    int written;

    if (dest == NULL || dest_size == 0 || source == NULL) {
        fprintf(stderr, "Missing %s value.\n", option_name);
        return 1;
    }

    written = snprintf(dest, dest_size, "%s", source);
    if (written < 0 || (size_t)written >= dest_size) {
        fprintf(stderr, "%s is too long.\n", option_name);
        return 1;
    }

    return 0;
}

static char *duplicate_path_value(const char *path, const char *option_name) {
    char *copy;

    if (path == NULL || *path == '\0') {
        fprintf(stderr, "Missing %s path.\n", option_name);
        return NULL;
    }

#ifdef linux
    {
        char resolved_path[PATH_MAX];
        if (realpath(path, resolved_path) != NULL) {
            path = resolved_path;
        } else if (errno != ENOENT && errno != ENOTDIR) {
            fprintf(stderr, "Failed to resolve %s path: %s\n", option_name, path);
            return NULL;
        }
    }
#endif

    copy = strdup(path);
    if (copy == NULL) {
        fprintf(stderr, "Out of memory while copying %s path.\n", option_name);
    }

    return copy;
}

static int replace_dynamic_string(char **target, char *replacement) {
    if (replacement == NULL) {
        return 1;
    }

    free(*target);
    *target = replacement;
    return 0;
}

static void cleanup_paths(char **file_path_ref) {
    if (file_path_ref != NULL) {
        free(*file_path_ref);
        *file_path_ref = NULL;
    }

    free(log_path);
    log_path = NULL;
}

int main(int argc, char *argv[]) {
    char *file_path = NULL;

    if (argc == 1) {
        print_help(1);
    }

    while (1) {
        static const struct option long_options[] = {
            {"mode", required_argument, 0, 'm'},
            {"conf", required_argument, 0, 'c'},
            {"bindip", required_argument, 0, 'b'},
            {"log", required_argument, 0, 'l'},
#ifdef linux
            {"daemon", no_argument, 0, 'd'},
            {"802.1x", no_argument, 0, 'x'},
#endif
            {"eternal", no_argument, 0, 'e'},
            {"verbose", no_argument, 0, 'v'},
            {"help", no_argument, 0, 'h'},
            {0, 0, 0, 0}};

        int c;
        int option_index = 0;
#ifdef linux
        c = getopt_long(argc, argv, "m:c:b:l:dxevh", long_options, &option_index);
#else
        c = getopt_long(argc, argv, "m:c:b:l:evh", long_options, &option_index);
#endif

        if (c == -1) {
            break;
        }

        switch (c) {
            case 'm':
                if (strcmp(optarg, "dhcp") != 0 && strcmp(optarg, "pppoe") != 0) {
                    fprintf(stderr, "unknown mode\n");
                    cleanup_paths(&file_path);
                    return 1;
                }
                if (copy_option_value(mode, sizeof(mode), optarg, "mode") != 0) {
                    cleanup_paths(&file_path);
                    return 1;
                }
                break;
            case 'c':
                if (replace_dynamic_string(&file_path, duplicate_path_value(optarg, "config")) != 0) {
                    cleanup_paths(&file_path);
                    return 1;
                }
                break;
            case 'b':
                if (copy_option_value(bind_ip, sizeof(bind_ip), optarg, "bind_ip") != 0) {
                    cleanup_paths(&file_path);
                    return 1;
                }
                break;
            case 'l':
                if (replace_dynamic_string(&log_path, duplicate_path_value(optarg, "log")) != 0) {
                    cleanup_paths(&file_path);
                    return 1;
                }
                logging_flag = 1;
                break;
#ifdef linux
            case 'd':
                daemon_flag = 1;
                break;
            case 'x':
                eapol_flag = 1;
                break;
#endif
            case 'e':
                eternal_flag = 1;
                break;
            case 'v':
                verbose_flag = 1;
                break;
            case 'h':
                print_help(0);
                break;
            case '?':
                print_help(1);
                break;
            default:
                break;
        }
    }

    if (mode[0] == '\0' || file_path == NULL) {
        fprintf(stderr, "Need more options!\n\n");
        cleanup_paths(&file_path);
        return 1;
    }

#ifdef linux
    if (daemon_flag) {
        daemonise();
    }
#endif

    if (config_parse(file_path) != 0) {
        cleanup_paths(&file_path);
        return 1;
    }

#ifdef linux
    if (eapol_flag) {
        if (0 != try_smart_eaplogin()) {
            fprintf(stderr, "Can't finish 802.1x authorization!\n");
            cleanup_paths(&file_path);
            return 1;
        }
    }
#endif

    if (bind_ip[0] == '\0') {
        if (copy_option_value(bind_ip, sizeof(bind_ip), default_bind_ip, "bind_ip") != 0) {
            cleanup_paths(&file_path);
            return 1;
        }
    }

    dogcom(5);
    cleanup_paths(&file_path);
    return 0;
}

void print_help(int exval) {
    printf("\nDrcom-generic implementation in C.\n");
    printf("Version: %s\n\n", VERSION);

    printf("Usage:\n");
    printf("\tdogcom -m <dhcp/pppoe> -c <FILEPATH> [options <argument>]...\n\n");

    printf("Options:\n");
    printf("\t--mode <dhcp/pppoe>, -m <dhcp/pppoe>  set your dogcom mode \n");
    printf("\t--conf <FILEPATH>, -c <FILEPATH>      import configuration file\n");
    printf("\t--bindip <IPADDR>, -b <IPADDR>        bind your ip address(default is 0.0.0.0)\n");
    printf("\t--log <LOGPATH>, -l <LOGPATH>         specify log file\n");
#ifdef linux
    printf("\t--daemon, -d                          set daemon flag\n");
    printf("\t--802.1x, -x                          enable 802.1x\n");
#endif
    printf("\t--eternal, -e                         set eternal flag\n");
    printf("\t--verbose, -v                         set verbose flag\n");
    printf("\t--help, -h                            display this help\n\n");
    exit(exval);
}

#ifdef linux
int try_smart_eaplogin(void) {
#define IFS_MAX (64)
    int ifcnt = IFS_MAX;
    iflist_t ifs[IFS_MAX];
    if (0 > getall_ifs(ifs, &ifcnt))
        return -1;

    for (int i = 0; i < ifcnt; ++i) {
        setifname(ifs[i].name);
        if (0 == eaplogin(drcom_config.username, drcom_config.password))
            return 0;
    }
    return -1;
}
#endif