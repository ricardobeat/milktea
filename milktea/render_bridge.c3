module milktea;

import xray;
import glaze;

// Rect.render fills this layout rect with content styled by style.
// This is the preferred way to render into a layout slot — the rect is the
// primary object (the slot you're filling), style and content are what goes in it.
fn String xray::Rect.render(self, glaze::Style style, String content) {
	return style.with_width(self.w).with_height(self.h).render(content);
}

// Style.render_in sizes content to the given rect and renders it.
// Prefer rect.render(style, content) when working with xray layouts.
fn String glaze::Style.render_in(self, xray::Rect rect, String content) {
	return self.with_width(rect.w).with_height(rect.h).render(content);
}
