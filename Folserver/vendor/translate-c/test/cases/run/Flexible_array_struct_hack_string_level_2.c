#include <stdlib.h>
#include <stdio.h>
typedef struct {
    int len;
    char data[0];
} String;
String *make_string(const char *str, int len) {
    String *s = (String *)malloc(sizeof(String) + len + 1);
    s->len = len;
    for (int i = 0; i < len; i++) {
        s->data[i] = str[i];
    }
    s->data[len] = '\0';
    return s;
}
int main(void) {
    String *s = make_string("hello", 5);
    printf("%s", s->data);
    free(s);
    return 0;
}

// run
// args = -fdefault-init -fstrict-flex-arrays=2
//
// hello
