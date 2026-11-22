#include "config.h"

#include <cstdio>
#include <cstdlib>

long env_long(const char *name, long fallback, long min, long max) {
  const char *v = std::getenv(name);
  if (v == nullptr || *v == '\0') return fallback;
  char *end = nullptr;
  long n = std::strtol(v, &end, 10);
  if (*end != '\0' || n < min || n > max) {
    std::fprintf(stderr, "invalid %s=%s (allowed %ld..%ld)\n", name, v, min, max);
    std::exit(2);
  }
  return n;
}

std::string env_str(const char *name, const char *fallback) {
  const char *v = std::getenv(name);
  return (v != nullptr && *v != '\0') ? v : fallback;
}
