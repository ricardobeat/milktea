module menubar_test;
import milktea;
import boba;
import xray;

const int NEW = 1;
const int OPEN = 2;
const int QUIT = 3;
const int UNDO = 4;

fn boba::MenuBar bar() {
	return boba::menu_bar({
		boba::menu("File", { boba::item("New", 'n', NEW), boba::item("Open", 'o', OPEN),
			boba::separator(), boba::item("Quit", 'q', QUIT) }),
		boba::menu("Edit", { boba::item("Undo", 'z', UNDO) }),
	});
}

fn milktea::Msg key(milktea::KeyCode code, uint rune = 0, bool ctrl = false) {
	return { .kind = milktea::MsgKind.KEY, .key = { .code = code, .rune = rune, .ctrl = ctrl } };
}

fn void test_shortcut_picks_without_opening() @test {
	boba::MenuBar b = bar();
	defer b.free();
	boba::MenuEvent ev = b.update(key(RUNE, 'o', ctrl: true));
	assert(ev.kind == PICKED && ev.id == OPEN);
	assert(!b.open);
	assert(b.update(key(RUNE, 'o')).kind == NONE, "a plain key is not a shortcut");
}

fn void test_keyboard_walks_menus_and_skips_separators() @test {
	boba::MenuBar b = bar();
	defer b.free();
	assert(b.update(key(F10)).kind == CONSUMED);
	assert(b.is_active());
	b.update(key(DOWN));                 // open File
	assert(b.open && b.selected == 0 && b.item == 0);
	b.update(key(DOWN));                 // Open
	b.update(key(DOWN));                 // past the separator to Quit
	assert(b.item == 3, "the separator is skipped");
	boba::MenuEvent ev = b.update(key(ENTER));
	assert(ev.kind == PICKED && ev.id == QUIT);
	assert(!b.open && !b.is_active(), "picking lets go of the keyboard");
}

fn void test_left_right_wrap_and_esc_dismisses() @test {
	boba::MenuBar b = bar();
	defer b.free();
	b.update(key(F10));
	b.update(key(LEFT));
	assert(b.selected == 1, "left from the first title wraps to the last");
	b.update(key(ENTER));
	assert(b.open && b.selected == 1);
	assert(b.update(key(ESC)).kind == DISMISSED);
	assert(!b.open && !b.is_active());
}

// A native item is tagged with its place (menu * 1024 + item + 1), so it
// comes back as itself even when the app gave its items no ids.
fn void test_native_pick_arrives_as_menu_message() @test {
	boba::MenuBar b = bar();
	defer b.free();
	boba::MenuEvent ev = b.update({ .kind = milktea::MsgKind.MENU, .tag = 1024 + 0 + 1 });
	assert(ev.kind == PICKED && ev.id == UNDO && ev.item.label == "Undo");
	assert(b.update({ .kind = milktea::MsgKind.MENU, .tag = 99 }).kind == NONE);
	assert(b.update({ .kind = milktea::MsgKind.MENU, .tag = 3 }).kind == NONE, "a separator is not picked");
}

fn void test_native_pick_without_ids() @test {
	boba::MenuBar b = boba::menu_bar({
		boba::menu("Help", { boba::item("Topics"), boba::item("About") }),
	});
	defer b.free();
	boba::MenuEvent ev = b.update({ .kind = milktea::MsgKind.MENU, .tag = 2 });
	assert(ev.kind == PICKED && ev.item.label == "About", "got %s", ev.item.label);
}

fn void test_terminal_shortcut_label() @test {
	assert(boba::shortcut_label('n') == "Ctrl+N", "no native menus: Ctrl");
}
