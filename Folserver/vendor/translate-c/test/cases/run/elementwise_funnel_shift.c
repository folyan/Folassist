#include <stdlib.h>

typedef unsigned int u4 __attribute__((vector_size(16)));

static void expect_u4(u4 actual, u4 expected) {
  if (actual[0] != expected[0])
    abort();
  if (actual[1] != expected[1])
    abort();
  if (actual[2] != expected[2])
    abort();
  if (actual[3] != expected[3])
    abort();
}

int main(void) {
  unsigned x = 0x12345678u;
  unsigned y = 0x9abcdef0u;

  if (__builtin_elementwise_fshl(x, y, 0u) != 0x12345678u)
    abort();
  if (__builtin_elementwise_fshl(x, y, 4u) != 0x23456789u)
    abort();
  if (__builtin_elementwise_fshl(x, y, 32u) != 0x12345678u)
    abort();
  if (__builtin_elementwise_fshl(x, y, 36u) != 0x23456789u)
    abort();

  if (__builtin_elementwise_fshr(x, y, 0u) != 0x9abcdef0u)
    abort();
  if (__builtin_elementwise_fshr(x, y, 4u) != 0x89abcdefu)
    abort();
  if (__builtin_elementwise_fshr(x, y, 32u) != 0x9abcdef0u)
    abort();
  if (__builtin_elementwise_fshr(x, y, 36u) != 0x89abcdefu)
    abort();

  u4 vx = {0x12345678u, 0x12345678u, 0x12345678u, 0x12345678u};
  u4 vy = {0x9abcdef0u, 0x9abcdef0u, 0x9abcdef0u, 0x9abcdef0u};
  u4 shifts = {0u, 4u, 32u, 36u};

  expect_u4(__builtin_elementwise_fshl(vx, vy, shifts),
            (u4){0x12345678u, 0x23456789u, 0x12345678u, 0x23456789u});
  expect_u4(__builtin_elementwise_fshr(vx, vy, shifts),
            (u4){0x9abcdef0u, 0x89abcdefu, 0x9abcdef0u, 0x89abcdefu});

  return 0;
}

// run
