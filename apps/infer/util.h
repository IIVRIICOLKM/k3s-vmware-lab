// Small string helpers shared by the HTTP handlers and the worker threads.
#pragma once

#include <string>
#include <vector>

// printf-style formatting into a std::string (output longer than 511 bytes is cut).
std::string fmt(const char *f, ...) __attribute__((format(printf, 1, 2)));

std::string error_json(const char *msg, size_t queue_len);

// Parses {"x":[f, f, ...]}: takes the numbers between the first '[' and the following ']'.
bool parse_input(const std::string &body, std::vector<float> &out);
