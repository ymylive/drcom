#ifndef RETRY_POLICY_H_
#define RETRY_POLICY_H_

#define DRCOM_SHORT_GENERIC_RETRY_DELAY_SECONDS 3
#define DRCOM_DEFAULT_LOGIN_RETRY_DELAY_SECONDS 60
#define DRCOM_KEEPALIVE_FAILURE_RECONNECT_THRESHOLD 6

int drcom_normalize_login_retry_delay(int seconds);
int drcom_retry_delay_for_login_reply(unsigned char reply_code, int recv_length, int retry_after_seconds);
int drcom_next_keepalive_failure_count(int current_failures, int keepalive_exchange_succeeded);
int drcom_should_reconnect_after_keepalive_failure(int consecutive_failures);

#endif  // RETRY_POLICY_H_
