#include <stdlib.h>

typedef unsigned int u4 __attribute__((vector_size(16)));

static void expect_u4(u4 actual, u4 expected) {
    if (actual[0] != expected[0]) abort();
    if (actual[1] != expected[1]) abort();
    if (actual[2] != expected[2]) abort();
    if (actual[3] != expected[3]) abort();
}

int main(void) {
    if (__builtin_elementwise_clzg(0u, 99u) != 99u) abort();
    if (__builtin_elementwise_clzg(1u, 99u) != 31u) abort();
    if (__builtin_elementwise_clzg(2u, 99u) != 30u) abort();
    if (__builtin_elementwise_clzg(8u, 99u) != 28u) abort();
    if (__builtin_elementwise_clzg(1u) != 31u) abort();

    u4 values = {0u, 1u, 2u, 8u};
    u4 fallback = {99u, 99u, 99u, 99u};
    expect_u4(__builtin_elementwise_clzg(values, fallback), (u4){99u, 31u, 30u, 28u});

    u4 nonzero = {1u, 2u, 4u, 8u};
    expect_u4(__builtin_elementwise_clzg(nonzero), (u4){31u, 30u, 29u, 28u});

    return 0;
}

// run
