#include <sys/ioctl.h>
#include <sys/time.h>
#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

int c3_get_winsize(int fd, unsigned short *row, unsigned short *col) {
    struct winsize ws;
    int result = ioctl(fd, TIOCGWINSZ, &ws);
    if (result == 0) {
        *row = ws.ws_row;
        *col = ws.ws_col;
    }
    return result;
}

long long c3_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, ((void *)0));
    return (long long)tv.tv_sec * 1000LL + tv.tv_usec / 1000LL;
}

long c3_time_ms_long(void) {
    struct timeval tv;
    gettimeofday(&tv, ((void *)0));
    return (long)tv.tv_sec * 1000L + tv.tv_usec / 1000L;
}

double c3_sin(double x) { return sin(x); }
double c3_cos(double x) { return cos(x); }

int c3_list_dir(char *path, char *names, int *is_dirs, int max_entries) {
    DIR *dir = opendir(path);
    if (!dir) return 0;

    struct dirent *ent;
    int count = 0;
    while ((ent = readdir(dir)) != ((void *)0) && count < max_entries) {
        const char *name = ent->d_name;
        int is_dir = (ent->d_type == DT_DIR) ? 1 : 0;

        /* Skip hidden files except . and .. */
        if (name[0] == '.' && !(name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
            continue;
        }

        strncpy(names + count * 256, name, 255);
        names[count * 256 + 255] = '\0';
        is_dirs[count] = is_dir;
        count++;
    }

    closedir(dir);
    return count;
}