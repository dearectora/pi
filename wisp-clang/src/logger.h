#pragma once
#include "config.h"
#include "openai.h"
#include <stdio.h>

typedef struct {
    FILE  *file;
    char  *last_message_id;
} SessionLogger;

/* Create a new session logger. Returns NULL on error. */
SessionLogger *logger_new(const Model *model);

/* Log a user message. Returns 0 on success. */
int logger_log_user(SessionLogger *lg, const char *text);

/* Log an assistant message. Returns 0 on success. */
int logger_log_assistant(SessionLogger *lg, const AssistantMessage *msg);

/* Close and free the logger. */
void logger_free(SessionLogger *lg);
