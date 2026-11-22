#include "util.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>

std::string fmt(const char *f, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, f);
  std::vsnprintf(buf, sizeof buf, f, ap);
  va_end(ap);
  return buf;
}

std::string error_json(const char *msg, size_t queue_len) {
  return fmt("{\"error\":\"%s\",\"queue\":%zu}", msg, queue_len);
}

bool parse_input(const std::string &body, std::vector<float> &out) {
  size_t open = body.find('['), close = body.find(']', open == std::string::npos ? 0 : open);
  if (open == std::string::npos || close == std::string::npos) return false;
  std::string inner = body.substr(open + 1, close - open - 1);
  const char *p = inner.c_str();
  while (*p != '\0') {
    while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\t' || *p == '\r') ++p;
    if (*p == '\0') break;
    char *end = nullptr;
    float v = std::strtof(p, &end);
    if (end == p || !std::isfinite(v)) return false;
    out.push_back(v);
    p = end;
  }
  return true;
}
