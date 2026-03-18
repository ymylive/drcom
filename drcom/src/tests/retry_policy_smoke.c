#include <stdio.h>

#include "../auth.h"
#include "../retry_policy.h"

static int expect_int(const char *name, int actual, int expected) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %d, got %d\n", name, expected, actual);
        return 1;
    }
    return 0;
}

int main(void) {
    int failures = 0;

    if (expect_int("short rejection retry", drcom_retry_delay_for_login_reply(WRONG_PASS, 5, 0), DRCOM_SHORT_GENERIC_RETRY_DELAY_SECONDS) != 0) {
        return 1;
    }
    if (expect_int("explicit wrong password retry", drcom_retry_delay_for_login_reply(WRONG_PASS, 6, 0), DRCOM_DEFAULT_LOGIN_RETRY_DELAY_SECONDS) != 0) {
        return 1;
    }
    if (expect_int("server cooldown retry", drcom_retry_delay_for_login_reply(UPDATE_CLIENT, 32, 180), 180) != 0) {
        return 1;
    }
    if (expect_int("update client default retry", drcom_retry_delay_for_login_reply(UPDATE_CLIENT, 32, 0), DRCOM_DEFAULT_LOGIN_RETRY_DELAY_SECONDS) != 0) {
        return 1;
    }
    if (expect_int("normalized retry", drcom_normalize_login_retry_delay(0), DRCOM_DEFAULT_LOGIN_RETRY_DELAY_SECONDS) != 0) {
        return 1;
    }

    failures = drcom_next_keepalive_failure_count(failures, 0);
    failures = drcom_next_keepalive_failure_count(failures, 0);
    if (expect_int("keepalive failures accumulate", failures, 2) != 0) {
        return 1;
    }

    failures = drcom_next_keepalive_failure_count(failures, 1);
    if (expect_int("keepalive success resets failures", failures, 0) != 0) {
        return 1;
    }

    if (expect_int("five failures stay connected", drcom_should_reconnect_after_keepalive_failure(5), 0) != 0) {
        return 1;
    }
    if (expect_int("six failures reconnect", drcom_should_reconnect_after_keepalive_failure(6), 1) != 0) {
        return 1;
    }

    printf("retry policy smoke tests passed\n");
    return 0;
}
