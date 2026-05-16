module stb_image;

extern fn char* stbi_load(char* filename, int* x, int* y, int* channels_in_file, int desired_channels);
extern fn void  stbi_image_free(void* retval_from_stbi_load);
extern fn void  stbi_set_flip_vertically_on_load(int flag_true_if_should_flip);
