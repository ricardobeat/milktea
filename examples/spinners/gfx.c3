module spinners;

// Procedural RGBA frames for the Kitty-graphics spinners. The canvas is 1:2
// (32x64 px) which roughly matches a terminal cell's aspect ratio, so circles
// drawn in pixel space come out circular on screen.

import std::math;

const int GFX_W = 32;
const int GFX_H = 64;
const int GFX_FRAMES = 8;
const int GFX_FRAME_BYTES = GFX_W * GFX_H * 4;

const uint ID_RING = 1000;
const uint ID_BALL   = 2000;
const uint ID_ORBIT  = 3000;

const float TAU = (float)(2.0 * math::PI);

fn float fclamp(float x, float lo, float hi) => x < lo ? lo : (x > hi ? hi : x);

fn void clear_frame(char* buf) {
	for (int i = 0; i < GFX_FRAME_BYTES; i++) buf[i] = 0;
}

fn void put(char* buf, int x, int y, float r, float g, float b, float a) {
	if (x < 0 || x >= GFX_W || y < 0 || y >= GFX_H || a <= 0) return;
	int i = (y * GFX_W + x) * 4;
	float da = (float)((int)buf[i + 3] & 0xff) / 255.0f;
	float oa = a + da * (1.0f - a);
	if (oa <= 0) return;
	float dr = (float)((int)buf[i] & 0xff) / 255.0f;
	float dg = (float)((int)buf[i + 1] & 0xff) / 255.0f;
	float db = (float)((int)buf[i + 2] & 0xff) / 255.0f;
	float w = da * (1.0f - a) / oa;
	float wa = a / oa;
	buf[i]     = (char)(int)(255.0f * fclamp(r * wa + dr * w, 0, 1));
	buf[i + 1] = (char)(int)(255.0f * fclamp(g * wa + dg * w, 0, 1));
	buf[i + 2] = (char)(int)(255.0f * fclamp(b * wa + db * w, 0, 1));
	buf[i + 3] = (char)(int)(oa * 255.0f);
}

fn void dot(char* buf, float cx, float cy, float radius, float r, float g, float b, float alpha) {
	int x0 = (int)(cx - radius - 1.0f);
	int x1 = (int)(cx + radius + 1.0f);
	int y0 = (int)(cy - radius - 1.0f);
	int y1 = (int)(cy + radius + 1.0f);
	for (int y = y0; y <= y1; y++) {
		for (int x = x0; x <= x1; x++) {
			float dx = (float)x - cx;
			float dy = (float)y - cy;
			float d = (float)math::sqrt(dx * dx + dy * dy);
			float cov = fclamp(radius + 0.5f - d, 0, 1);
			if (cov > 0) put(buf, x, y, r, g, b, cov * alpha);
		}
	}
}

fn void ellipse(char* buf, float cx, float cy, float rx, float ry,
	float r_top, float g_top, float b_top, float r_bot, float g_bot, float b_bot, float alpha) {
	int x0 = (int)(cx - rx - 1.0f);
	int x1 = (int)(cx + rx + 1.0f);
	int y0 = (int)(cy - ry - 1.0f);
	int y1 = (int)(cy + ry + 1.0f);
	for (int y = y0; y <= y1; y++) {
		for (int x = x0; x <= x1; x++) {
			float nx = ((float)x - cx) / rx;
			float ny = ((float)y - cy) / ry;
			float e = (float)math::sqrt(nx * nx + ny * ny);
			float cov = fclamp(1.0f + 0.08f - e, 0, 1);
			if (cov <= 0) continue;
			float k = fclamp(ny * 0.5f + 0.5f, 0, 1);
			put(buf, x, y,
				r_top + (r_bot - r_top) * k,
				g_top + (g_bot - g_top) * k,
				b_top + (b_bot - b_top) * k,
				cov * alpha);
		}
	}
}

const int RING_FRAMES = 16;

fn void gen_ring(char* buf, int frame) {
	clear_frame(buf);
	float head = (float)frame / RING_FRAMES * TAU;
	float cx = (GFX_W - 1) / 2.0f;
	float cy = (GFX_H - 1) / 2.0f;
	float radius = 12.5f;
	float tail = TAU * 0.75f;
	for (int y = 0; y < GFX_H; y++) {
		for (int x = 0; x < GFX_W; x++) {
			float dx = (float)x - cx;
			float dy = (float)y - cy;
			float distance = (float)math::sqrt(dx * dx + dy * dy) - radius;
			if (distance < 0) distance = -distance;
			float coverage = fclamp(3.5f - distance, 0, 1);
			if (coverage <= 0) continue;
			float lag = head - (float)math::atan2(dy, dx);
			lag -= (float)math::floor(lag / TAU) * TAU;
			float fade = fclamp(1.0f - lag / tail, 0, 1);
			put(buf, x, y, 0.15f, 0.85f, 1.0f, coverage * fade * fade);
		}
	}
	// Round the bright leading end of the arc.
	dot(buf, cx + radius * (float)math::cos(head), cy + radius * (float)math::sin(head),
		3.0f, 0.15f, 0.85f, 1.0f, 1.0f);
}

fn void gen_ball(char* buf, int frame) {
	clear_frame(buf);
	float t = (float)frame / GFX_FRAMES;
	float par = 2.0f * t - 1.0f;
	float h = 1.0f - par * par;
	float squash = (float)math::exp(-6.0f * h);
	float r0 = 9.0f;
	float rx = r0 * (1.0f + 0.55f * squash);
	float ry = r0 * (1.0f - 0.38f * squash);
	float floor_y = GFX_H - 5.0f;
	float cx = (GFX_W - 1) / 2.0f;
	float cy = floor_y - ry + 1.0f - h * 34.0f;

	ellipse(buf, cx, floor_y + 1.5f, r0 * (1.15f - 0.45f * h), 2.2f,
		0.05f, 0.05f, 0.10f, 0.05f, 0.05f, 0.10f, 0.45f * (1.0f - 0.75f * h));

	ellipse(buf, cx, cy, rx, ry,
		1.0f, 0.70f, 0.28f,
		1.0f, 0.18f, 0.47f,
		1.0f);

	dot(buf, cx - rx * 0.35f, cy - ry * 0.40f, r0 * 0.28f, 1, 1, 1, 0.35f * (1.0f - 0.5f * squash));
}

const float[5] ORBIT_COLORS_R = { 0.26, 0.92, 0.98, 0.20, 0.98 };
const float[5] ORBIT_COLORS_G = { 0.52, 0.26, 0.74, 0.66, 0.48 };
const float[5] ORBIT_COLORS_B = { 0.96, 0.21, 0.02, 0.33, 0.09 };

fn void gen_orbit(char* buf, int frame) {
	clear_frame(buf);
	float cx = (GFX_W - 1) / 2.0f;
	float cy = (GFX_H - 1) / 2.0f;
	float base = (float)frame / GFX_FRAMES * TAU;

	for (int y = 0; y < GFX_H; y++) {
		for (int x = 0; x < GFX_W; x++) {
			float dx = (float)x - cx;
			float dy = (float)y - cy;
			float rad = (float)math::sqrt(dx * dx + dy * dy);
			float dr = rad - 11.0f;
			if (dr < 0) dr = -dr;
			float cov = fclamp(0.6f - dr, 0, 1);
			if (cov > 0) put(buf, x, y, 1, 1, 1, cov * 0.15f);
		}
	}

	for (int k = 0; k < 5; k++) {
		float ang = base + (float)k * (TAU / 5.0f);
		float px = cx + 11.0f * (float)math::cos(ang);
		float py = cy + 11.0f * (float)math::sin(ang);
		float rad = 4.2f * (1.0f + 0.18f * (float)math::sin(2.0f * ang + base));
		dot(buf, px, py, rad, ORBIT_COLORS_R[k], ORBIT_COLORS_G[k], ORBIT_COLORS_B[k], 1.0f);
	}
}

const int CUBE_FRAMES = 24;

fn void gen_cube(char* buf, int frame) {
	clear_frame(buf);
	float angle = (float)frame / CUBE_FRAMES * TAU;
	float cs = (float)math::cos(angle);
	float sn = (float)math::sin(angle);
	float ct = (float)math::cos(0.48f);
	float st = (float)math::sin(0.48f);
	// Rows of the inverse rotation also give each local face's world normal.
	float[3][3] rotation = { { cs, sn * st, -sn * ct }, { 0, ct, st }, { sn, -cs * st, cs * ct } };
	float cx = (GFX_W - 1) / 2.0f;
	float cy = (GFX_H - 1) / 2.0f;
	for (int y = 0; y < GFX_H; y++) {
		for (int x = 0; x < GFX_W; x++) {
			// Four orthographic ray samples per pixel soften the silhouette.
			for (int sample = 0; sample < 4; sample++) {
				float px = (float)x - cx + (sample % 2 == 0 ? -0.25f : 0.25f);
				float py = (float)y - cy + (sample / 2 == 0 ? -0.25f : 0.25f);
				float near = 0;
				float far = 100;
				int face = 0;
				float sign = 1;
				bool hit = true;
				for (int axis = 0; axis < 3; axis++) {
					float origin = rotation[axis][0] * px + rotation[axis][1] * py - rotation[axis][2] * 40.0f;
					float direction = rotation[axis][2];
					if (direction > -0.0001f && direction < 0.0001f) {
						if (origin < -9.0f || origin > 9.0f) hit = false;
						continue;
					}
					float entry = (-9.0f - origin) / direction;
					float exit = (9.0f - origin) / direction;
					float normal_sign = -1;
					if (entry > exit) {
						float swap = entry;
						entry = exit;
						exit = swap;
						normal_sign = 1;
					}
					if (entry > near) { near = entry; face = axis; sign = normal_sign; }
					if (exit < far) far = exit;
				}
				if (!hit || near > far) continue;
				float light = sign * (-0.4f * rotation[face][0] - 0.6f * rotation[face][1] - 0.7f * rotation[face][2]);
				float shade = 0.28f + 0.72f * fclamp(light, 0, 1);
				// Accumulate premultiplied samples, then normalize below.
				int offset = (y * GFX_W + x) * 4;
				buf[offset] += (char)(int)(0.25f * shade * 255.0f / 4.0f);
				buf[offset + 1] += (char)(int)(0.70f * shade * 255.0f / 4.0f);
				buf[offset + 2] += (char)(int)(shade * 255.0f / 4.0f);
				buf[offset + 3] += 63;
			}
			int offset = (y * GFX_W + x) * 4;
			int alpha = (int)buf[offset + 3];
			if (alpha == 0) continue;
			for (int channel = 0; channel < 3; channel++) {
				buf[offset + channel] = (char)((int)buf[offset + channel] * 255 / alpha);
			}
		}
	}
}
