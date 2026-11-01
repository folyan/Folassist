float sdot_(const int *n, const float *x, const int *incx, const float *y, const int *incy);
double ddot_(const int *n, const double *x, const int *incx, const double *y, const int *incy);

void sdotsub_(const int *n, const float *x, const int *incx, const float *y, const int *incy, float *res) {
    *res = sdot_(n, x, incx, y, incy);
}

void ddotsub_(const int *n, const double *x, const int *incx, const double *y, const int *incy, double *res) {
    *res = ddot_(n, x, incx, y, incy);
}
