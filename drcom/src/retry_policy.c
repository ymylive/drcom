#include "auth.h"
#include "retry_policy.h"

int drcom_normalize_login_retry_delay(int seconds) {
    return seconds > 0 ? seconds : DRCOM_DEFAULT_LOGIN_RETRY_DELAY_SECONDS;
}

int drcom_retry_delay_for_login_reply(unsigned char reply_code, int recv_length, int retry_after_seconds) {
    if (reply_code == WRONG_PASS && recv_length <= 5) {
        return DRCOM_SHORT_GENERIC_RETRY_DELAY_SECONDS;
    }

    if (reply_code == UPDATE_CLIENT && retry_after_seconds > 0) {
        return retry_after_seconds;
    }

    return DRCOM_DEFAULT_LOGIN_RETRY_DELAY_SECONDS;
}

int drcom_next_keepalive_failure_count(int current_failures, int keepalive_exchange_succeeded) {
    if (keepalive_exchange_succeeded) {
        return 0;
    }

    if (current_failures < 0) {
        current_failures = 0;
    }

    return current_failures + 1;
}

int drcom_should_reconnect_after_keepalive_failure(int consecutive_failures) {
    return consecutive_failures >= DRCOM_KEEPALIVE_FAILURE_RECONNECT_THRESHOLD;
}
