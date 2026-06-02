module snapshot;

import std::io;
import std::io::path;
import std::os::env;
import std::core::dstring;

const String SNAPSHOT_UPDATE_KEY = "UPDATE_SNAPSHOTS";
const String SNAPSHOT_BASE_DIR = "snapshots";

// Returns true when UPDATE_SNAPSHOTS env var is set.
fn bool update_requested() {
	String? val = os::env::tget_var(SNAPSHOT_UPDATE_KEY);
	if (catch e = val) return false;
	return val == "1" || val == "true";
}

// Construct the snapshot file path: snapshots/{subdir}/{name}.snap
fn String snap_path(String subdir, String name) {
	DString d = dstring::temp();
	d.append(SNAPSHOT_BASE_DIR);
	d.append("/");
	d.append(subdir);
	d.append("/");
	d.append(name);
	d.append(".snap");
	return d.str_view();
}

// Ensure a directory exists (recursive mkdir).
fn void ensure_dir(String path) {
	bool? mkdir_ok = path::mkdir(path, true);
}

// Write actual output to the snapshot file.
fn void update_snapshot(String subdir, String name, String actual) {
	ensure_dir(SNAPSHOT_BASE_DIR);
	String dir = string::tformat("%s/%s", SNAPSHOT_BASE_DIR, subdir);
	ensure_dir(dir);
	String path = snap_path(subdir, name);
	(void)io::file::save(path, actual);
}

// Compare actual output against the stored snapshot.
// If UPDATE_SNAPSHOTS is set, writes the new snapshot instead.
// If no snapshot exists yet, creates it.
fn void assert_snapshot(String subdir, String name, String actual) {
	if (update_requested()) {
		update_snapshot(subdir, name, actual);
		return;
	}

	String path = snap_path(subdir, name);

	if (!io::file::exists(path)) {
		update_snapshot(subdir, name, actual);
		io::printfn("  [snapshot] created: %s/%s.snap", subdir, name);
		return;
	}

	char[]? loaded = io::file::load_temp(path);
	if (catch err = loaded) {
		io::printfn("  [snapshot] ERROR: could not load %s", path);
		return;
	}

	String expected = (String)loaded;
	if (actual != expected) {
		io::printfn("  [snapshot] MISMATCH: %s/%s", subdir, name);
		io::printfn("  expected (%d bytes):", expected.len);
		io::printfn("  actual   (%d bytes):", actual.len);
		sz min_len = actual.len < expected.len ? actual.len : expected.len;
		for (sz i = 0; i < min_len; i++) {
			if (actual[i] != expected[i]) {
				io::printfn("  first diff at byte %d", i);
				break;
			}
		}
		io::printfn("  run: UPDATE_SNAPSHOTS=1 c3c test to update");
	}
}
