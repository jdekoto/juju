#include <stdio.h>
int jj_fdiv(int,int), jj_div(int,int), jj_mod(int,int), jj_shr(int), jj_sum(int), jj_arr(void), jj_struct(void),
    jj_sc(int,int), jj_tern(int), jj_defer(void), jj_slice(void), jj_str(void), jj_enum(void), jj_u8(void),
    jj_tab(int), jj_early(int), jj_default(int,int), jj_dcall(void), jj_negfloor(void), jj_ptr(void),
    jj_global(void), jj_while(void), jj_idx8(void);
static int fails = 0, total = 0;
#define CHECK(expr, want) do { int got = (expr); total++; if (got != (want)) { printf("FAIL %s: got %d, want %d\n", #expr, got, (want)); fails++; } } while (0)
int main(void) {
    CHECK(jj_fdiv(-7, 2), -4);  CHECK(jj_fdiv(7, 2), 3);  CHECK(jj_fdiv(7, -2), -4);  CHECK(jj_fdiv(-8, 2), -4);  CHECK(jj_fdiv(6, 3), 2);
    CHECK(jj_div(-7, 2), -3);   CHECK(jj_mod(-7, 3), -1); CHECK(jj_mod(7, 3), 1);
    CHECK(jj_shr(-16), -4);     CHECK(jj_sum(5), 10);     CHECK(jj_arr(), 41);       CHECK(jj_struct(), 62);
    CHECK(jj_sc(1, 1), 1);      CHECK(jj_sc(1, -1), 2);   CHECK(jj_sc(-1, 1), 2);    CHECK(jj_sc(-1, -1), 3);
    CHECK(jj_tern(9), 10);      CHECK(jj_tern(1), 20);    CHECK(jj_defer(), 101);    CHECK(jj_slice(), 302);
    CHECK(jj_str(), 5);         CHECK(jj_enum(), 11);     CHECK(jj_u8(), 44);        CHECK(jj_tab(2), 30);
    CHECK(jj_early(10), 8);     CHECK(jj_default(1, 7), 107); CHECK(jj_dcall(), 409); CHECK(jj_negfloor(), -4);
    CHECK(jj_ptr(), 21);        CHECK(jj_global(), 7);    CHECK(jj_while(), 15);     CHECK(jj_idx8(), 77);
    printf("%d/%d checks passed\n", total - fails, total);
    return fails != 0;
}
