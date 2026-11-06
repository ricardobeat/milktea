sokol headers from https://github.com/floooh/sokol at 2e75443.

## Local patch

`sokol_gfx.h`, `_sg_mtl_end_pass`: the drawable is not presented on the
command buffer when its layer has `presentsWithTransaction` set; the caller
presents it (see `gui/backend.m`, `mt_present`). Search for `MILKTEA PATCH`
when updating sokol.
