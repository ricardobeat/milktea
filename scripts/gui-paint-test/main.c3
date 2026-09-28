module gui_paint_test;

import milktea;
import milktea_gui;
import glaze;
import xray;
import raylib6::rl;
import std::os::env;
import std::io;

struct Scene (milktea::Model) { bool changed; }
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
	return milktea::draw(milktea::root()
		.add(milktea::text(base, ""))
		.add(panel)
		.add(milktea::text(blue, "").at(9, 4)
			.width(milktea::cells(6)).height(milktea::cells(3)))
		.add(milktea::text(base, "").at(3, 7)
			.width(milktea::cells(2)).height(milktea::cells(2))
			.decorate(xray::solid(xray::color_rgb(255, 0, 255)))));
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
	assert(scene.changed);
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
	io::printn("GUI paint-order pixels passed");
	return 0;
}
