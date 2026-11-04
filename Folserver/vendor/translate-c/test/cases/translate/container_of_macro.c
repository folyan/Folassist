#define wl_container_of(ptr, sample, member)				\
	(__typeof__(sample))((char *)(ptr) -				\
			     offsetof(__typeof__(*sample), member))

// translate
//
// pub const wl_container_of = __helpers.WL_CONTAINER_OF;
