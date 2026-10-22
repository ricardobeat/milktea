module milktea;

import std::core::dstring;

// base64_encode returns the standard base64 form of input, padded with '='.
//
// Both terminal protocols that carry binary data use it: OSC 52 for the
// clipboard, and the kitty graphics protocol for image payloads.
fn String base64_encode(char[] input) {
	const String B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	DString out = dstring::temp();

	sz i = 0;
	while (i < input.len) {
		sz remaining = input.len - i;
		sz b0 = (sz)input[i] & 0xff;
		sz b1 = remaining > 1 ? ((sz)input[i + 1] & 0xff) : 0;
		sz b2 = remaining > 2 ? ((sz)input[i + 2] & 0xff) : 0;

		out.append_char(B64[(b0 >> 2) & 0x3f]);
		out.append_char(B64[((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0f)]);
		out.append_char(remaining > 1 ? B64[((b1 & 0x0f) << 2) | ((b2 >> 6) & 0x03)] : '=');
		out.append_char(remaining > 2 ? B64[b2 & 0x3f] : '=');

		i += 3;
	}

	return out.str_view();
}
