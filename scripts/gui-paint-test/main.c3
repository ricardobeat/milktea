module gui_paint_test;

import milktea;
import milktea_gui;
import glaze;
import xray;
import raylib6::rl;
import std::os::env;
import std::io;

struct Scene (milktea::Model) {
	bool changed;
	bool checked_padding;
	int hit_count, hit_col, hit_row;
}
fn void padded_click(void* ctx, String id, int col, int row) {
	Scene* scene = (Scene*)ctx;
	scene.hit_count++;
	scene.hit_col = col;
	scene.hit_row = row;
}
fn milktea::Cmd Scene.init(&self) @dynamic => null;
fn milktea::Cmd Scene.update(&self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.KEY) self.changed = true;
	return null;
}

fn milktea::View Scene.view(&self) @dynamic {
	glaze::Style base = { .bg = glaze::color_hex("#204060") };
	glaze::Style green = { .bg = glaze::color_hex("#00ff00") };
	glaze::Style blue = { .bg = glaze::color_hex("#0000ff") };
	xray::Color fill = self.changed ? xray::color_rgb(255, 255, 0) : xray::color_rgb(255, 0, 0);
	xray::Node* panel = milktea::text(base, "")
		.at(2, 2).width(milktea::cells(10)).height(milktea::cells(8))
		.decorate(xray::linear(fill, xray::color_rgb(128, 0, 0)).round(15.0f))
		.add(milktea::text(green, "").at(2, 2)
			.width(milktea::cells(2)).height(milktea::cells(2)));
	milktea::View view = milktea::draw(milktea::root()
		.add(milktea::text(base, ""))
		.add(panel)
		.add(milktea::text(blue, "").at(9, 4)
			.width(milktea::cells(6)).height(milktea::cells(3)))
		.add(milktea::text(base, "").at(3, 7)
			.width(milktea::cells(2)).height(milktea::cells(2))
			.decorate(xray::solid(xray::color_rgb(255, 0, 255))))
		.add(milktea::vbox(base).at(18, 2)
			.width(milktea::cells(8)).height(milktea::cells(3))
			.decorate(xray::solid(xray::color_rgb(255, 0, 0)).padding(3, 5, 7, 4))
			.add(milktea::text(green, "").id_with(self).on_click(&padded_click)))
		.add(milktea::text({ .fg = glaze::color_hex("#00ff00") }, "█").at(18, 10)
			.width(milktea::cells(8)).height(milktea::cells(1))
			.decorate(xray::solid(xray::color_rgb(255, 0, 0)).padding(4, 4, 4, 4))));
	if (!self.checked_padding) {
		milktea::dispatch_click(183, 23);
		assert(self.hit_count == 0);
		milktea::dispatch_click(184, 23);
		assert(self.hit_count == 1 && self.hit_col == 0 && self.hit_row == 0);
		milktea::dispatch_click(193, 32);
		assert(self.hit_count == 2 && self.hit_col == 0 && self.hit_row == 0);
		milktea::dispatch_click(194, 33);
		assert(self.hit_count == 3 && self.hit_col == 1 && self.hit_row == 1);
		milktea::dispatch_click(264, 23);
		milktea::dispatch_click(184, 53);
		assert(self.hit_count == 3);
		self.checked_padding = true;
	}
	return view;
}

fn void expect_pixel(rl::RLImage image, int x, int y, rl::RLColor expected) {
	float sx = (float)image.width / 320.0f;
	float sy = (float)image.height / 240.0f;
	rl::RLColor got = rl::get_image_color(image, (int)((float)x * sx), (int)((float)y * sy));
	assert(got[0] == expected[0] && got[1] == expected[1] && got[2] == expected[2],
		"paint order pixel mismatch");
}

fn int main() {
	env::set_var("MILKTEA_DEBUG_KEY_AT", "space,4", true);
	Scene scene;
	milktea_gui::run(&scene, {
		.title = "Paint order regression", .cols = 32, .rows = 24,
		.cell_w = 10, .cell_h = 10, .font_size = 10,
		.screenshot_path = "out/paint.png",
	});
	assert(scene.changed && scene.checked_padding && scene.hit_count == 3);
	rl::RLImage image = rl::load_image("out/paint.png");
	defer rl::unload_image(image);
	assert(image.width > 0);
	expect_pixel(image, 5, 5, {32, 64, 96, 255});
	expect_pixel(image, 20, 20, {32, 64, 96, 255}); // rounded corner exposes parent
	float sx = (float)image.width / 320.0f;
	float sy = (float)image.height / 240.0f;
	rl::RLColor gradient = rl::get_image_color(image, (int)(70.0f * sx), (int)(35.0f * sy));
	assert(gradient[0] > 200 && gradient[1] > 150 && gradient[1] < 240 && gradient[2] == 0,
		"gradient-only update was skipped or covered");
	expect_pixel(image, 45, 45, {0, 255, 0, 255}); // child above parent gradient
	expect_pixel(image, 100, 50, {0, 0, 255, 255}); // later popup above decoration
	expect_pixel(image, 35, 75, {255, 0, 255, 255}); // second texture upload
	expect_pixel(image, 183, 23, {255, 0, 0, 255});
	expect_pixel(image, 184, 23, {0, 255, 0, 255});
	expect_pixel(image, 263, 52, {0, 255, 0, 255});
	expect_pixel(image, 264, 52, {255, 0, 0, 255});
	expect_pixel(image, 184, 22, {255, 0, 0, 255});
	expect_pixel(image, 184, 53, {255, 0, 0, 255});
	expect_pixel(image, 269, 23, {32, 64, 96, 255});
	expect_pixel(image, 183, 104, {255, 0, 0, 255});
	expect_pixel(image, 184, 104, {0, 255, 0, 255});
	expect_pixel(image, 193, 113, {0, 255, 0, 255});
	expect_pixel(image, 194, 113, {255, 0, 0, 255});
	expect_pixel(image, 184, 103, {255, 0, 0, 255});
	expect_pixel(image, 184, 114, {255, 0, 0, 255});
	io::printn("GUI paint order, pixel padding, and hit targets passed");
	return 0;
}
