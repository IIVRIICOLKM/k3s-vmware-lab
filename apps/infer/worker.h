// Worker thread: takes batches from the queue, fails requests that waited too long, computes the rest together.
#pragma once

#include "backend.h"
#include "config.h"
#include "metrics.h"
#include "queue.h"

// Runs until the queue is closed. Each thread owns one Executor from `backend`.
void worker_loop(const Config &cfg, const Backend &backend, Queue &queue, Metrics &metrics);
