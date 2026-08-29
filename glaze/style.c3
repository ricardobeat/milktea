module glaze;

import std::core::dstring;

// Stack capacity for Style.render's per-call line table. Content beyond this
// falls back to a heap allocation rather than being truncated — the array is
// sized to the actual line count either way.
const sz STACK_RENDER_LINES = 256;

// BorderAnimation selects an animated border rendering mode.
enum BorderAnimation : char {
	NONE,    // static border (default)
	PULSE,   // pulses the base color in brightness
	RAINBOW, // rainbow colors spin around the perimeter
	RACE,    // a dash of bright color races around, leaving a dim trail
}

// codepoint_width returns the terminal display width of a single Unicode
// codepoint. This is a byte-identical copy of xray::char_width — glaze is
// built without xray in several targets, so it cannot import it. Both are
// generated from the same Unicode data by scripts/gen_width.py, and
// test_glaze_and_xray_widths_agree compares them across the whole codepoint
// range at build time, so the two cannot drift.
fn int codepoint_width(uint cp) {
	return glaze_width_lookup(cp);
}

// BEGIN GENERATED WIDTH TABLES — edit scripts/gen_width.py, run `just gen-width`
// A half-open-free inclusive codepoint range, sorted ascending.
struct CodepointRange { uint lo; uint hi; }

const CodepointRange[357] GLAZE_WIDTH_ZERO_RANGES = {
	{ 0x0000, 0x0000 },
	{ 0x0300, 0x036F },
	{ 0x0483, 0x0489 },
	{ 0x0591, 0x05BD },
	{ 0x05BF, 0x05BF },
	{ 0x05C1, 0x05C2 },
	{ 0x05C4, 0x05C5 },
	{ 0x05C7, 0x05C7 },
	{ 0x0600, 0x0605 },
	{ 0x0610, 0x061A },
	{ 0x061C, 0x061C },
	{ 0x064B, 0x065F },
	{ 0x0670, 0x0670 },
	{ 0x06D6, 0x06DD },
	{ 0x06DF, 0x06E4 },
	{ 0x06E7, 0x06E8 },
	{ 0x06EA, 0x06ED },
	{ 0x070F, 0x070F },
	{ 0x0711, 0x0711 },
	{ 0x0730, 0x074A },
	{ 0x07A6, 0x07B0 },
	{ 0x07EB, 0x07F3 },
	{ 0x07FD, 0x07FD },
	{ 0x0816, 0x0819 },
	{ 0x081B, 0x0823 },
	{ 0x0825, 0x0827 },
	{ 0x0829, 0x082D },
	{ 0x0859, 0x085B },
	{ 0x0890, 0x0891 },
	{ 0x0898, 0x089F },
	{ 0x08CA, 0x0902 },
	{ 0x093A, 0x093A },
	{ 0x093C, 0x093C },
	{ 0x0941, 0x0948 },
	{ 0x094D, 0x094D },
	{ 0x0951, 0x0957 },
	{ 0x0962, 0x0963 },
	{ 0x0981, 0x0981 },
	{ 0x09BC, 0x09BC },
	{ 0x09C1, 0x09C4 },
	{ 0x09CD, 0x09CD },
	{ 0x09E2, 0x09E3 },
	{ 0x09FE, 0x09FE },
	{ 0x0A01, 0x0A02 },
	{ 0x0A3C, 0x0A3C },
	{ 0x0A41, 0x0A42 },
	{ 0x0A47, 0x0A48 },
	{ 0x0A4B, 0x0A4D },
	{ 0x0A51, 0x0A51 },
	{ 0x0A70, 0x0A71 },
	{ 0x0A75, 0x0A75 },
	{ 0x0A81, 0x0A82 },
	{ 0x0ABC, 0x0ABC },
	{ 0x0AC1, 0x0AC5 },
	{ 0x0AC7, 0x0AC8 },
	{ 0x0ACD, 0x0ACD },
	{ 0x0AE2, 0x0AE3 },
	{ 0x0AFA, 0x0AFF },
	{ 0x0B01, 0x0B01 },
	{ 0x0B3C, 0x0B3C },
	{ 0x0B3F, 0x0B3F },
	{ 0x0B41, 0x0B44 },
	{ 0x0B4D, 0x0B4D },
	{ 0x0B55, 0x0B56 },
	{ 0x0B62, 0x0B63 },
	{ 0x0B82, 0x0B82 },
	{ 0x0BC0, 0x0BC0 },
	{ 0x0BCD, 0x0BCD },
	{ 0x0C00, 0x0C00 },
	{ 0x0C04, 0x0C04 },
	{ 0x0C3C, 0x0C3C },
	{ 0x0C3E, 0x0C40 },
	{ 0x0C46, 0x0C48 },
	{ 0x0C4A, 0x0C4D },
	{ 0x0C55, 0x0C56 },
	{ 0x0C62, 0x0C63 },
	{ 0x0C81, 0x0C81 },
	{ 0x0CBC, 0x0CBC },
	{ 0x0CBF, 0x0CBF },
	{ 0x0CC6, 0x0CC6 },
	{ 0x0CCC, 0x0CCD },
	{ 0x0CE2, 0x0CE3 },
	{ 0x0D00, 0x0D01 },
	{ 0x0D3B, 0x0D3C },
	{ 0x0D41, 0x0D44 },
	{ 0x0D4D, 0x0D4D },
	{ 0x0D62, 0x0D63 },
	{ 0x0D81, 0x0D81 },
	{ 0x0DCA, 0x0DCA },
	{ 0x0DD2, 0x0DD4 },
	{ 0x0DD6, 0x0DD6 },
	{ 0x0E31, 0x0E31 },
	{ 0x0E34, 0x0E3A },
	{ 0x0E47, 0x0E4E },
	{ 0x0EB1, 0x0EB1 },
	{ 0x0EB4, 0x0EBC },
	{ 0x0EC8, 0x0ECE },
	{ 0x0F18, 0x0F19 },
	{ 0x0F35, 0x0F35 },
	{ 0x0F37, 0x0F37 },
	{ 0x0F39, 0x0F39 },
	{ 0x0F71, 0x0F7E },
	{ 0x0F80, 0x0F84 },
	{ 0x0F86, 0x0F87 },
	{ 0x0F8D, 0x0F97 },
	{ 0x0F99, 0x0FBC },
	{ 0x0FC6, 0x0FC6 },
	{ 0x102D, 0x1030 },
	{ 0x1032, 0x1037 },
	{ 0x1039, 0x103A },
	{ 0x103D, 0x103E },
	{ 0x1058, 0x1059 },
	{ 0x105E, 0x1060 },
	{ 0x1071, 0x1074 },
	{ 0x1082, 0x1082 },
	{ 0x1085, 0x1086 },
	{ 0x108D, 0x108D },
	{ 0x109D, 0x109D },
	{ 0x135D, 0x135F },
	{ 0x1712, 0x1714 },
	{ 0x1732, 0x1733 },
	{ 0x1752, 0x1753 },
	{ 0x1772, 0x1773 },
	{ 0x17B4, 0x17B5 },
	{ 0x17B7, 0x17BD },
	{ 0x17C6, 0x17C6 },
	{ 0x17C9, 0x17D3 },
	{ 0x17DD, 0x17DD },
	{ 0x180B, 0x180F },
	{ 0x1885, 0x1886 },
	{ 0x18A9, 0x18A9 },
	{ 0x1920, 0x1922 },
	{ 0x1927, 0x1928 },
	{ 0x1932, 0x1932 },
	{ 0x1939, 0x193B },
	{ 0x1A17, 0x1A18 },
	{ 0x1A1B, 0x1A1B },
	{ 0x1A56, 0x1A56 },
	{ 0x1A58, 0x1A5E },
	{ 0x1A60, 0x1A60 },
	{ 0x1A62, 0x1A62 },
	{ 0x1A65, 0x1A6C },
	{ 0x1A73, 0x1A7C },
	{ 0x1A7F, 0x1A7F },
	{ 0x1AB0, 0x1ACE },
	{ 0x1B00, 0x1B03 },
	{ 0x1B34, 0x1B34 },
	{ 0x1B36, 0x1B3A },
	{ 0x1B3C, 0x1B3C },
	{ 0x1B42, 0x1B42 },
	{ 0x1B6B, 0x1B73 },
	{ 0x1B80, 0x1B81 },
	{ 0x1BA2, 0x1BA5 },
	{ 0x1BA8, 0x1BA9 },
	{ 0x1BAB, 0x1BAD },
	{ 0x1BE6, 0x1BE6 },
	{ 0x1BE8, 0x1BE9 },
	{ 0x1BED, 0x1BED },
	{ 0x1BEF, 0x1BF1 },
	{ 0x1C2C, 0x1C33 },
	{ 0x1C36, 0x1C37 },
	{ 0x1CD0, 0x1CD2 },
	{ 0x1CD4, 0x1CE0 },
	{ 0x1CE2, 0x1CE8 },
	{ 0x1CED, 0x1CED },
	{ 0x1CF4, 0x1CF4 },
	{ 0x1CF8, 0x1CF9 },
	{ 0x1DC0, 0x1DFF },
	{ 0x200B, 0x200F },
	{ 0x202A, 0x202E },
	{ 0x2060, 0x2064 },
	{ 0x2066, 0x206F },
	{ 0x20D0, 0x20F0 },
	{ 0x2CEF, 0x2CF1 },
	{ 0x2D7F, 0x2D7F },
	{ 0x2DE0, 0x2DFF },
	{ 0x302A, 0x302D },
	{ 0x3099, 0x309A },
	{ 0xA66F, 0xA672 },
	{ 0xA674, 0xA67D },
	{ 0xA69E, 0xA69F },
	{ 0xA6F0, 0xA6F1 },
	{ 0xA802, 0xA802 },
	{ 0xA806, 0xA806 },
	{ 0xA80B, 0xA80B },
	{ 0xA825, 0xA826 },
	{ 0xA82C, 0xA82C },
	{ 0xA8C4, 0xA8C5 },
	{ 0xA8E0, 0xA8F1 },
	{ 0xA8FF, 0xA8FF },
	{ 0xA926, 0xA92D },
	{ 0xA947, 0xA951 },
	{ 0xA980, 0xA982 },
	{ 0xA9B3, 0xA9B3 },
	{ 0xA9B6, 0xA9B9 },
	{ 0xA9BC, 0xA9BD },
	{ 0xA9E5, 0xA9E5 },
	{ 0xAA29, 0xAA2E },
	{ 0xAA31, 0xAA32 },
	{ 0xAA35, 0xAA36 },
	{ 0xAA43, 0xAA43 },
	{ 0xAA4C, 0xAA4C },
	{ 0xAA7C, 0xAA7C },
	{ 0xAAB0, 0xAAB0 },
	{ 0xAAB2, 0xAAB4 },
	{ 0xAAB7, 0xAAB8 },
	{ 0xAABE, 0xAABF },
	{ 0xAAC1, 0xAAC1 },
	{ 0xAAEC, 0xAAED },
	{ 0xAAF6, 0xAAF6 },
	{ 0xABE5, 0xABE5 },
	{ 0xABE8, 0xABE8 },
	{ 0xABED, 0xABED },
	{ 0xFB1E, 0xFB1E },
	{ 0xFE00, 0xFE0F },
	{ 0xFE20, 0xFE2F },
	{ 0xFEFF, 0xFEFF },
	{ 0xFFF9, 0xFFFB },
	{ 0x101FD, 0x101FD },
	{ 0x102E0, 0x102E0 },
	{ 0x10376, 0x1037A },
	{ 0x10A01, 0x10A03 },
	{ 0x10A05, 0x10A06 },
	{ 0x10A0C, 0x10A0F },
	{ 0x10A38, 0x10A3A },
	{ 0x10A3F, 0x10A3F },
	{ 0x10AE5, 0x10AE6 },
	{ 0x10D24, 0x10D27 },
	{ 0x10EAB, 0x10EAC },
	{ 0x10EFD, 0x10EFF },
	{ 0x10F46, 0x10F50 },
	{ 0x10F82, 0x10F85 },
	{ 0x11001, 0x11001 },
	{ 0x11038, 0x11046 },
	{ 0x11070, 0x11070 },
	{ 0x11073, 0x11074 },
	{ 0x1107F, 0x11081 },
	{ 0x110B3, 0x110B6 },
	{ 0x110B9, 0x110BA },
	{ 0x110BD, 0x110BD },
	{ 0x110C2, 0x110C2 },
	{ 0x110CD, 0x110CD },
	{ 0x11100, 0x11102 },
	{ 0x11127, 0x1112B },
	{ 0x1112D, 0x11134 },
	{ 0x11173, 0x11173 },
	{ 0x11180, 0x11181 },
	{ 0x111B6, 0x111BE },
	{ 0x111C9, 0x111CC },
	{ 0x111CF, 0x111CF },
	{ 0x1122F, 0x11231 },
	{ 0x11234, 0x11234 },
	{ 0x11236, 0x11237 },
	{ 0x1123E, 0x1123E },
	{ 0x11241, 0x11241 },
	{ 0x112DF, 0x112DF },
	{ 0x112E3, 0x112EA },
	{ 0x11300, 0x11301 },
	{ 0x1133B, 0x1133C },
	{ 0x11340, 0x11340 },
	{ 0x11366, 0x1136C },
	{ 0x11370, 0x11374 },
	{ 0x11438, 0x1143F },
	{ 0x11442, 0x11444 },
	{ 0x11446, 0x11446 },
	{ 0x1145E, 0x1145E },
	{ 0x114B3, 0x114B8 },
	{ 0x114BA, 0x114BA },
	{ 0x114BF, 0x114C0 },
	{ 0x114C2, 0x114C3 },
	{ 0x115B2, 0x115B5 },
	{ 0x115BC, 0x115BD },
	{ 0x115BF, 0x115C0 },
	{ 0x115DC, 0x115DD },
	{ 0x11633, 0x1163A },
	{ 0x1163D, 0x1163D },
	{ 0x1163F, 0x11640 },
	{ 0x116AB, 0x116AB },
	{ 0x116AD, 0x116AD },
	{ 0x116B0, 0x116B5 },
	{ 0x116B7, 0x116B7 },
	{ 0x1171D, 0x1171F },
	{ 0x11722, 0x11725 },
	{ 0x11727, 0x1172B },
	{ 0x1182F, 0x11837 },
	{ 0x11839, 0x1183A },
	{ 0x1193B, 0x1193C },
	{ 0x1193E, 0x1193E },
	{ 0x11943, 0x11943 },
	{ 0x119D4, 0x119D7 },
	{ 0x119DA, 0x119DB },
	{ 0x119E0, 0x119E0 },
	{ 0x11A01, 0x11A0A },
	{ 0x11A33, 0x11A38 },
	{ 0x11A3B, 0x11A3E },
	{ 0x11A47, 0x11A47 },
	{ 0x11A51, 0x11A56 },
	{ 0x11A59, 0x11A5B },
	{ 0x11A8A, 0x11A96 },
	{ 0x11A98, 0x11A99 },
	{ 0x11C30, 0x11C36 },
	{ 0x11C38, 0x11C3D },
	{ 0x11C3F, 0x11C3F },
	{ 0x11C92, 0x11CA7 },
	{ 0x11CAA, 0x11CB0 },
	{ 0x11CB2, 0x11CB3 },
	{ 0x11CB5, 0x11CB6 },
	{ 0x11D31, 0x11D36 },
	{ 0x11D3A, 0x11D3A },
	{ 0x11D3C, 0x11D3D },
	{ 0x11D3F, 0x11D45 },
	{ 0x11D47, 0x11D47 },
	{ 0x11D90, 0x11D91 },
	{ 0x11D95, 0x11D95 },
	{ 0x11D97, 0x11D97 },
	{ 0x11EF3, 0x11EF4 },
	{ 0x11F00, 0x11F01 },
	{ 0x11F36, 0x11F3A },
	{ 0x11F40, 0x11F40 },
	{ 0x11F42, 0x11F42 },
	{ 0x13430, 0x13440 },
	{ 0x13447, 0x13455 },
	{ 0x16AF0, 0x16AF4 },
	{ 0x16B30, 0x16B36 },
	{ 0x16F4F, 0x16F4F },
	{ 0x16F8F, 0x16F92 },
	{ 0x16FE4, 0x16FE4 },
	{ 0x1BC9D, 0x1BC9E },
	{ 0x1BCA0, 0x1BCA3 },
	{ 0x1CF00, 0x1CF2D },
	{ 0x1CF30, 0x1CF46 },
	{ 0x1D167, 0x1D169 },
	{ 0x1D173, 0x1D182 },
	{ 0x1D185, 0x1D18B },
	{ 0x1D1AA, 0x1D1AD },
	{ 0x1D242, 0x1D244 },
	{ 0x1DA00, 0x1DA36 },
	{ 0x1DA3B, 0x1DA6C },
	{ 0x1DA75, 0x1DA75 },
	{ 0x1DA84, 0x1DA84 },
	{ 0x1DA9B, 0x1DA9F },
	{ 0x1DAA1, 0x1DAAF },
	{ 0x1E000, 0x1E006 },
	{ 0x1E008, 0x1E018 },
	{ 0x1E01B, 0x1E021 },
	{ 0x1E023, 0x1E024 },
	{ 0x1E026, 0x1E02A },
	{ 0x1E08F, 0x1E08F },
	{ 0x1E130, 0x1E136 },
	{ 0x1E2AE, 0x1E2AE },
	{ 0x1E2EC, 0x1E2EF },
	{ 0x1E4EC, 0x1E4EF },
	{ 0x1E8D0, 0x1E8D6 },
	{ 0x1E944, 0x1E94A },
	{ 0xE0001, 0xE0001 },
	{ 0xE0020, 0xE007F },
	{ 0xE0100, 0xE01EF },
};

const CodepointRange[122] GLAZE_WIDTH_WIDE_RANGES = {
	{ 0x1100, 0x115F },
	{ 0x231A, 0x231B },
	{ 0x2329, 0x232A },
	{ 0x23E9, 0x23EC },
	{ 0x23F0, 0x23F0 },
	{ 0x23F3, 0x23F3 },
	{ 0x25FD, 0x25FE },
	{ 0x2614, 0x2615 },
	{ 0x2648, 0x2653 },
	{ 0x267F, 0x267F },
	{ 0x2693, 0x2693 },
	{ 0x26A1, 0x26A1 },
	{ 0x26AA, 0x26AB },
	{ 0x26BD, 0x26BE },
	{ 0x26C4, 0x26C5 },
	{ 0x26CE, 0x26CE },
	{ 0x26D4, 0x26D4 },
	{ 0x26EA, 0x26EA },
	{ 0x26F2, 0x26F3 },
	{ 0x26F5, 0x26F5 },
	{ 0x26FA, 0x26FA },
	{ 0x26FD, 0x26FD },
	{ 0x2705, 0x2705 },
	{ 0x270A, 0x270B },
	{ 0x2728, 0x2728 },
	{ 0x274C, 0x274C },
	{ 0x274E, 0x274E },
	{ 0x2753, 0x2755 },
	{ 0x2757, 0x2757 },
	{ 0x2795, 0x2797 },
	{ 0x27B0, 0x27B0 },
	{ 0x27BF, 0x27BF },
	{ 0x2B1B, 0x2B1C },
	{ 0x2B50, 0x2B50 },
	{ 0x2B55, 0x2B55 },
	{ 0x2E80, 0x2E99 },
	{ 0x2E9B, 0x2EF3 },
	{ 0x2F00, 0x2FD5 },
	{ 0x2FF0, 0x2FFB },
	{ 0x3000, 0x3029 },
	{ 0x302E, 0x303E },
	{ 0x3041, 0x3096 },
	{ 0x309B, 0x30FF },
	{ 0x3105, 0x312F },
	{ 0x3131, 0x318E },
	{ 0x3190, 0x31E3 },
	{ 0x31F0, 0x321E },
	{ 0x3220, 0x3247 },
	{ 0x3250, 0x4DBF },
	{ 0x4E00, 0xA48C },
	{ 0xA490, 0xA4C6 },
	{ 0xA960, 0xA97C },
	{ 0xAC00, 0xD7A3 },
	{ 0xF900, 0xFAFF },
	{ 0xFE10, 0xFE19 },
	{ 0xFE30, 0xFE52 },
	{ 0xFE54, 0xFE66 },
	{ 0xFE68, 0xFE6B },
	{ 0xFF01, 0xFF60 },
	{ 0xFFE0, 0xFFE6 },
	{ 0x16FE0, 0x16FE3 },
	{ 0x16FF0, 0x16FF1 },
	{ 0x17000, 0x187F7 },
	{ 0x18800, 0x18CD5 },
	{ 0x18D00, 0x18D08 },
	{ 0x1AFF0, 0x1AFF3 },
	{ 0x1AFF5, 0x1AFFB },
	{ 0x1AFFD, 0x1AFFE },
	{ 0x1B000, 0x1B122 },
	{ 0x1B132, 0x1B132 },
	{ 0x1B150, 0x1B152 },
	{ 0x1B155, 0x1B155 },
	{ 0x1B164, 0x1B167 },
	{ 0x1B170, 0x1B2FB },
	{ 0x1F004, 0x1F004 },
	{ 0x1F0CF, 0x1F0CF },
	{ 0x1F18E, 0x1F18E },
	{ 0x1F191, 0x1F19A },
	{ 0x1F200, 0x1F202 },
	{ 0x1F210, 0x1F23B },
	{ 0x1F240, 0x1F248 },
	{ 0x1F250, 0x1F251 },
	{ 0x1F260, 0x1F265 },
	{ 0x1F300, 0x1F320 },
	{ 0x1F32D, 0x1F335 },
	{ 0x1F337, 0x1F37C },
	{ 0x1F37E, 0x1F393 },
	{ 0x1F3A0, 0x1F3CA },
	{ 0x1F3CF, 0x1F3D3 },
	{ 0x1F3E0, 0x1F3F0 },
	{ 0x1F3F4, 0x1F3F4 },
	{ 0x1F3F8, 0x1F43E },
	{ 0x1F440, 0x1F440 },
	{ 0x1F442, 0x1F4FC },
	{ 0x1F4FF, 0x1F53D },
	{ 0x1F54B, 0x1F54E },
	{ 0x1F550, 0x1F567 },
	{ 0x1F57A, 0x1F57A },
	{ 0x1F595, 0x1F596 },
	{ 0x1F5A4, 0x1F5A4 },
	{ 0x1F5FB, 0x1F64F },
	{ 0x1F680, 0x1F6C5 },
	{ 0x1F6CC, 0x1F6CC },
	{ 0x1F6D0, 0x1F6D2 },
	{ 0x1F6D5, 0x1F6D7 },
	{ 0x1F6DC, 0x1F6DF },
	{ 0x1F6EB, 0x1F6EC },
	{ 0x1F6F4, 0x1F6FC },
	{ 0x1F7E0, 0x1F7EB },
	{ 0x1F7F0, 0x1F7F0 },
	{ 0x1F90C, 0x1F93A },
	{ 0x1F93C, 0x1F945 },
	{ 0x1F947, 0x1F9FF },
	{ 0x1FA70, 0x1FA7C },
	{ 0x1FA80, 0x1FA88 },
	{ 0x1FA90, 0x1FABD },
	{ 0x1FABF, 0x1FAC5 },
	{ 0x1FACE, 0x1FADB },
	{ 0x1FAE0, 0x1FAE8 },
	{ 0x1FAF0, 0x1FAF8 },
	{ 0x20000, 0x2FFFD },
	{ 0x30000, 0x3FFFD },
};

fn bool glaze_width_in_ranges(CodepointRange[] ranges, uint cp) @local {
	usz lo = 0;
	usz hi = ranges.len;
	while (lo < hi) {
		usz mid = lo + (hi - lo) / 2;
		if (cp < ranges[mid].lo) {
			hi = mid;
		} else if (cp > ranges[mid].hi) {
			lo = mid + 1;
		} else {
			return true;
		}
	}
	return false;
}

fn int glaze_width_lookup(uint cp) @local {
	// Fast path: ASCII is by far the most common input and is
	// entirely width 1 apart from NUL, which the zero table covers.
	if (cp >= 0x20 && cp < 0x7F) return 1;
	if (glaze_width_in_ranges(GLAZE_WIDTH_ZERO_RANGES[..], cp)) return 0;
	if (glaze_width_in_ranges(GLAZE_WIDTH_WIDE_RANGES[..], cp)) return 2;
	return 1;
}
// END GENERATED WIDTH TABLES

// skip_escape returns the index just past the escape sequence starting at
// `start` (which must point at ESC), or s.len if the sequence is unterminated.
//
// CSI (ESC [ ...) ends at the first byte in 0x40..0x7e. OSC (ESC ] ...) runs
// until BEL or ST (ESC \) and may legitimately contain letters — treating it
// like a CSI ended the scan on the first letter in the payload and counted the
// remainder as visible text. viewport.c3 emits OSC 52 for clipboard writes, so
// this is a sequence that really does flow through here.
fn sz skip_escape(String s, sz start) @local {
	sz i = start + 1; // past ESC
	if (i >= s.len) return s.len;

	char kind = s[i];
	if (kind == ']') {
		i++;
		while (i < s.len) {
			if (s[i] == 0x07) return i + 1; // BEL
			if (s[i] == 0x1b && i + 1 < s.len && s[i + 1] == '\\') return i + 2; // ST
			i++;
		}
		return s.len;
	}

	if (kind == '[') {
		i++;
		while (i < s.len) {
			if (s[i] >= 0x40 && s[i] <= 0x7e) return i + 1;
			i++;
		}
		return s.len;
	}

	// Two-byte escapes (ESC M, ESC 7, ...) and anything unrecognised: consume
	// the single following byte.
	return i + 1;
}

// truncate_to_width returns the longest prefix of `s` whose display width is
// at most `max_width`, measured the same way as string_width.
//
// Escape sequences are carried through whole and cost no width, so the result
// never ends in the middle of one — cutting at a byte index would emit the
// leading bytes of a CSI as literal visible text. Multi-byte characters are
// likewise kept intact, and a wide glyph that would straddle the limit is
// dropped rather than half-included.
fn String truncate_to_width(String s, int max_width) {
	if (max_width <= 0) return "";
	int w = 0;
	sz i  = 0;
	while (i < s.len) {
		if (s[i] == '\x1b') {
			i = skip_escape(s, i);
			continue;
		}
		sz char_len = utf8_sequence_len(s, i);
		uint cp     = decode_codepoint(s, i, char_len);
		int cw      = codepoint_width(cp);
		if (w + cw > max_width) break;
		w += cw;
		i += char_len;
	}
	return s[:i];
}

// utf8_sequence_len returns the byte length of the UTF-8 sequence at `i`,
// clamped to the end of the string. Always at least 1, so callers advance.
fn sz utf8_sequence_len(String s, sz i) {
	char b = s[i];
	sz n   = 1;
	if ((b & 0xe0) == 0xc0) {
		n = 2;
	} else if ((b & 0xf0) == 0xe0) {
		n = 3;
	} else if ((b & 0xf8) == 0xf0) {
		n = 4;
	}
	return i + n > s.len ? s.len - i : n;
}

// decode_codepoint decodes the `len`-byte UTF-8 sequence starting at `i`.
fn uint decode_codepoint(String s, sz i, sz len) @local {
	char b = s[i];
	switch (len) {
		case 2: return ((uint)(b & 0x1f) << 6) | (uint)(s[i + 1] & 0x3f);
		case 3:
			return ((uint)(b & 0x0f) << 12) | ((uint)(s[i + 1] & 0x3f) << 6) | (uint)(s[i + 2] & 0x3f);
		case 4:
			return ((uint)(b & 0x07) << 18) | ((uint)(s[i + 1] & 0x3f) << 12)
				| ((uint)(s[i + 2] & 0x3f) << 6) | (uint)(s[i + 3] & 0x3f);
		default: return (uint)b;
	}
}

// utf8_width_at returns the display width of the UTF-8 sequence starting at
// index `i`. Callers stepping through a string character by character should
// advance their column counter by this amount, not by one: a wide glyph (CJK,
// emoji) occupies two terminal columns, so counting it once misaligns
// selection and padding on lines that contain one.
fn int utf8_width_at(String s, sz i) {
	return codepoint_width(decode_codepoint(s, i, utf8_sequence_len(s, i)));
}

// string_width returns the terminal display width of a string, skipping ANSI
// escape sequences. Uses the same codepoint width rules as xray::char_width.
fn int string_width(String s) {
	int w = 0;
	sz i  = 0;
	while (i < s.len) {
		if (s[i] == '\x1b') {
			i = skip_escape(s, i);
			continue;
		}

		// Decode UTF-8 codepoint
		uint cp = 0;
		char b  = s[i];
		if ((b & 0x80) == 0) {
			cp = (uint)b;
			i++;
		} else if ((b & 0xe0) == 0xc0) {
			cp = (uint)(b & 0x1f);
			i++;
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
		} else if ((b & 0xf0) == 0xe0) {
			cp = (uint)(b & 0x0f);
			i++;
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
		} else if ((b & 0xf8) == 0xf0) {
			cp = (uint)(b & 0x07);
			i++;
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
			if (i < s.len) {
				cp = (cp << 6) | (uint)(s[i] & 0x3f);
				i++;
			}
		} else {
			i++;
			continue;
		}

		w += codepoint_width(cp);
	}
	return w;
}

struct Style {
	Color fg;
	Color bg;
	Color border_color;
	// Background behind the border. Unset means the border sits on the block's
	// own background, which is right for a box drawn around its content. A
	// border used as a drop shadow wants the surface behind the block instead,
	// so that the half of each cell the shadow does not cover shows it.
	Color border_bg;
	bool bold;
	bool italic;
	bool underline;
	int pad_top;
	int pad_right;
	int pad_bottom;
	int pad_left;
	int width; // 0 = auto (don't pad)
	int height; // 0 = auto
	Position align_h; // horizontal alignment within width
	Position align_v; // vertical alignment within height
	Border border; // zero value = no border
	BorderAnimation border_animation; // NONE = static
	int anim_speed_ms; // ms per full cycle (default 1000)
}

fn Style style() {
	return { };
}

fn Style Style.foreground(self, Color c) {
	Style s = self;
	s.fg = c;
	return s;
}

fn Style Style.background(self, Color c) {
	Style s = self;
	s.bg = c;
	return s;
}

fn Style Style.with_bold(self, bool v) {
	Style s = self;
	s.bold = v;
	return s;
}

fn Style Style.with_italic(self, bool v) {
	Style s = self;
	s.italic = v;
	return s;
}

fn Style Style.with_underline(self, bool v) {
	Style s = self;
	s.underline = v;
	return s;
}

// pad applies the same padding to all four sides.
fn Style Style.pad(self, int n) => self.padding(n, n, n, n);

// pad_x and pad_y pad one axis, which is the common case for a label or a
// status line that needs breathing room on the sides but not above.
fn Style Style.pad_x(self, int n) {
	Style s = self;
	s.pad_left = n;
	s.pad_right = n;
	return s;
}

fn Style Style.pad_y(self, int n) {
	Style s = self;
	s.pad_top = n;
	s.pad_bottom = n;
	return s;
}

fn Style Style.padding(self, int top, int right, int bottom, int left) {
	Style s = self;
	s.pad_top = top;
	s.pad_right = right;
	s.pad_bottom = bottom;
	s.pad_left = left;
	return s;
}

fn Style Style.with_width(self, int w) {
	Style s = self;
	s.width = w;
	return s;
}

fn Style Style.with_border(self, Border b) {
	Style s = self;
	s.border = b;
	return s;
}

fn Style Style.border_fg(self, Color c) {
	Style s = self;
	s.border_color = c;
	return s;
}

fn Style Style.border_anim(self, BorderAnimation anim) {
	Style s = self;
	s.border_animation = anim;
	if (s.anim_speed_ms == 0) s.anim_speed_ms = 1000;
	return s;
}

fn Style Style.border_anim_speed(self, int ms) {
	Style s = self;
	s.anim_speed_ms = ms;
	return s;
}

fn Style Style.with_height(self, int h) {
	Style s = self;
	s.height = h;
	return s;
}

fn Style Style.align(self, Position h, Position v) {
	Style s = self;
	s.align_h = h;
	s.align_v = v;
	return s;
}

fn Style Style.align_horizontal(self, Position h) {
	Style s = self;
	s.align_h = h;
	return s;
}

fn Style Style.align_vertical(self, Position v) {
	Style s = self;
	s.align_v = v;
	return s;
}

fn Style Style.with_fg(self, String hex) {
	return self.foreground(color_hex(hex));
}

fn Style Style.with_bg(self, String hex) {
	return self.background(color_hex(hex));
}

// measure_height renders content at the given outer width and counts the output lines.
// Useful for auto-sizing a box before committing it to a layout rect.
fn int Style.measure_height(self, String input, int outer_width) {
	// width() means total outer width (border+pad+content); render() subtracts border internally.
	Style sized     = self.with_width(outer_width);
	String rendered = sized.render(input);
	int lines       = 1;
	for (sz i = 0; i < rendered.len; i++) {
		if (rendered[i] == '\n') lines++;
	}
	return lines;
}

fn void color_whitespace(DString* buf, Color* bg, bool has_bg, int n) @local {
	if (n <= 0) return;
	if (has_bg) {
		buf.append_string("\x1b[");
		bg.write_sgr_params(buf, false);
		buf.append_string("m");
	}
	for (int j = 0; j < n; j++) buf.append_char(' ');
	if (has_bg) buf.append_string("\x1b[0m");
}

// next_sgr_channels looks at the escape sequence starting at `pos`, if there
// is one, and reports whether it sets a foreground and/or a background color.
// A style re-applying itself after an inner reset uses this to leave alone
// whatever the content is about to set for itself.
fn void next_sgr_channels(String s, sz pos, bool* fg, bool* bg) @local {
	*fg = false;
	*bg = false;
	if (pos + 2 >= s.len || s[pos] != '\x1b' || s[pos + 1] != '[') return;

	sz i = pos + 2;
	int code = 0;
	bool have = false;
	while (i < s.len && s[i] != 'm') {
		if (s[i] >= '0' && s[i] <= '9') {
			code = code * 10 + (s[i] - '0');
			have = true;
		} else if (s[i] == ';') {
			if (have) mark_sgr_channel(code, fg, bg);
			code = 0;
			have = false;
		} else {
			// Not an SGR sequence.
			return;
		}
		i++;
	}
	if (i < s.len && have) mark_sgr_channel(code, fg, bg);
}

// mark_sgr_channel records which channel one SGR parameter sets. 30-38 and
// 90-97 are foreground, 40-48 and 100-107 background; 39 and 49 reset a
// channel to the default, which still counts as the content deciding it.
fn void mark_sgr_channel(int code, bool* fg, bool* bg) @local {
	if ((code >= 30 && code <= 39) || (code >= 90 && code <= 97)) *fg = true;
	if ((code >= 40 && code <= 49) || (code >= 100 && code <= 107)) *bg = true;
}

fn String Style.render(self, String input) {
	DString out = dstring::temp();

	// Split input into lines. The line table is sized to the actual line
	// count: a fixed stack array would silently truncate content beyond its
	// capacity, and rendering a long log or file is an ordinary thing to ask
	// for. Count first, then use a stack buffer when it fits, falling back to
	// a heap allocation only for unusually long content.
	sz line_count = 1;
	for (sz i = 0; i < input.len; i++) {
		if (input[i] == '\n') line_count++;
	}

	String[STACK_RENDER_LINES] stack_lines;
	String* lines = stack_lines[..].ptr;
	String* heap_lines = null;
	if (line_count > STACK_RENDER_LINES) {
		heap_lines = mem::new_array(String, line_count).ptr;
		lines = heap_lines;
	}
	defer {
		if (heap_lines != null) mem::free(heap_lines);
	}

	sz line_index = 0;
	sz line_start = 0;
	for (sz i = 0; i <= input.len; i++) {
		if (i == input.len || input[i] == '\n') {
			lines[line_index] = input[line_start:i - line_start];
			line_index++;
			line_start = i + 1;
		}
	}

	// Determine target width.
	// In Go glaze, Width(N) means total output = N (border + padding included).
	// So we subtract border and padding from the requested width to get the
	// content area width.
	int border_h = 0;
	bool border_is_empty = self.border.top.len == 0 && self.border.bottom.len == 0 && self.border.left.len == 0
		&& self.border.right.len == 0
		&& self.border.top_left.len == 0
		&& self.border.top_right.len == 0
		&& self.border.bottom_left.len == 0
		&& self.border.bottom_right.len == 0;
	if (!border_is_empty) {
		border_h = 2; // left + right border chars
	}

	int target_width = self.width;
	if (target_width > 0) {
		// Subtract border and padding to get content area
		target_width = target_width - border_h - self.pad_left - self.pad_right;
		if (target_width < 1) target_width = 1;
	} else {
		// Auto-size to widest line
		target_width = 0;
		for (sz i = 0; i < line_count; i++) {
			int line_width = string_width(lines[i]);
			if (line_width > target_width) target_width = line_width;
		}
	}

	bool has_attrs = self.fg.kind != ColorKind.NONE || self.bg.kind != ColorKind.NONE || self.bold || self.italic
		|| self.underline;
	bool has_bg = self.bg.kind != ColorKind.NONE;

	// Total line width = content + padding (border is applied after)
	int line_width = target_width + self.pad_left + self.pad_right;

	// Build content into a temp buffer first, then add height alignment.
	DString body = dstring::temp();

	// Top padding lines.
	for (int i = 0; i < self.pad_top; i++) {
		color_whitespace(&body, &self.bg, has_bg, line_width);
		body.append_char('\n');
	}

	// Content lines.
	for (sz i = 0; i < line_count; i++) {
		String line = lines[i];

		// Build styled line: pad_left + [align_h lead] + content + fill + pad_right.
		int content_w   = string_width(line);
		int slack       = target_width - content_w;
		if (slack < 0) slack = 0;
		int h_lead      = 0;
		if (self.align_h == Position.CENTER) { h_lead = slack / 2; }
		else if (self.align_h == Position.RIGHT) { h_lead = slack; }
		int fill        = slack - h_lead;

		// Pad left + horizontal alignment lead.
		color_whitespace(&body, &self.bg, has_bg, self.pad_left + h_lead);

		// Content (styled).
		if (has_attrs) {
			body.append_string("\x1b[");
			bool first = true;
			if (self.bold) {
				body.append_string("1");
				first = false;
			}
			if (self.italic) {
				if (!first) body.append_char(';');
				body.append_string("3");
				first = false;
			}
			if (self.underline) {
				if (!first) body.append_char(';');
				body.append_string("4");
				first = false;
			}
			if (self.fg.kind != ColorKind.NONE) {
				if (!first) body.append_char(';');
				self.fg.write_sgr_params(&body, true);
				first = false;
			}
			if (has_bg) {
				if (!first) body.append_char(';');
				self.bg.write_sgr_params(&body, false);
			}
			body.append_string("m");
			// Write line content, re-applying outer style after any inner resets.
			sz li = 0;
			while (li < line.len) {
				// Detect \x1b[0m or \x1b[0;...m (full reset)
				if (line[li] == '\x1b' && li + 2 < line.len && line[li+1] == '[') {
					// Find end of escape
					sz esc_start = li;
					li += 2;
					while (li < line.len && line[li] != 'm' && line[li] != 'A' && line[li] != 'B'
						&& line[li] != 'C' && line[li] != 'D' && line[li] != 'H'
						&& line[li] != 'J' && line[li] != 'K') li++;
					if (li < line.len) li++;
					body.append_string(line[esc_start:li - esc_start]);
					// A reset inside the content drops this style along with the
					// content's own, so re-apply it — but only the channels the
					// content does not set for itself right after. Content that
					// resets and immediately re-colors, as a nested border does,
					// would otherwise have its color overwritten by this one.
					if (line[esc_start + 2] == '0') {
						// The reset may carry its own colors — \x1b[0;38;2;..m
						// is a reset and a foreground in one sequence — so look
						// inside it as well as at whatever follows.
						bool sets_fg;
						bool sets_bg;
						next_sgr_channels(line[esc_start:li - esc_start], 0, &sets_fg, &sets_bg);
						if (!sets_fg || !sets_bg) {
							bool nfg;
							bool nbg;
							next_sgr_channels(line, li, &nfg, &nbg);
							sets_fg = sets_fg || nfg;
							sets_bg = sets_bg || nbg;
						}
						if (self.bold && !sets_fg) body.append_string("\x1b[1m");
						if (self.fg.kind != ColorKind.NONE && !sets_fg) {
							body.append_string("\x1b[");
							self.fg.write_sgr_params(&body, true);
							body.append_string("m");
						}
						if (has_bg && !sets_bg) {
							body.append_string("\x1b[");
							self.bg.write_sgr_params(&body, false);
							body.append_string("m");
						}
					}
				} else {
					body.append_char(line[li]);
					li++;
				}
			}
			body.append_string("\x1b[0m");
		} else {
			body.append_string(line);
		}

		// Fill + pad right.
		color_whitespace(&body, &self.bg, has_bg, fill + self.pad_right);

		body.append_char('\n');
	}

	// Bottom padding lines.
	for (int i = 0; i < self.pad_bottom; i++) {
		color_whitespace(&body, &self.bg, has_bg, line_width);
		body.append_char('\n');
	}

	// Height: add empty lines to reach target height, with vertical alignment.
	// height means total outer height (like Go glaze v2), so subtract border.
	int border_v      = !border_is_empty ? 2 : 0;
	int height_target = self.height - border_v;
	if (height_target < 0) height_target = 0;
	int total_lines = (int)line_count + self.pad_top + self.pad_bottom;
	if (height_target > 0 && total_lines < height_target) {
		int extra        = height_target - total_lines;
		int top_extra    = 0;
		int bottom_extra = 0;
		if (self.align_v == Position.CENTER) {
			top_extra = extra / 2;
			bottom_extra = extra - top_extra;
		} else if (self.align_v == Position.BOTTOM) {
			top_extra = extra;
		} else {
			bottom_extra = extra;
		}

		for (int i = 0; i < top_extra; i++) {
			color_whitespace(&out, &self.bg, has_bg, line_width);
			out.append_char('\n');
		}
		out.append_string(body.str_view());
		for (int i = 0; i < bottom_extra; i++) {
			color_whitespace(&out, &self.bg, has_bg, line_width);
			out.append_char('\n');
		}
	} else {
		out.append_string(body.str_view());
	}

	// Remove trailing newline if needed, then apply border or copy.
	String rendered = out.str_view();
	if (rendered.len > 0 && rendered[rendered.len - 1] == '\n') {
		rendered = rendered[:rendered.len - 1];
	}

	// height is the block's total height, so content taller than it is clipped
	// rather than allowed to overflow. A block that grew past the size it was
	// given would paint over whatever the layout put below it — including its
	// own drop shadow.
	if (height_target > 0 && total_lines > height_target) {
		rendered = clip_lines(rendered, height_target);
	}

	if (!border_is_empty) {
		Color bbg = self.border_bg.kind != ColorKind.NONE ? self.border_bg : self.bg;
		return self.border.wrap_with_color(rendered, self.border_color, bbg);
	}
	return rendered.tcopy();
}

// render_content_only renders the styled content WITHOUT the border.
// The caller's width/height should already account for border overhead.
// Used by animated border rendering to separate content from border.
fn String Style.render_content_only(self, String input) {
	// Temporarily clear the border, render, then restore.
	Style saved = self;
	Style s     = self;
	s.border = { };
	s.border_color = { };
	s.border_animation = BorderAnimation.NONE;
	String result = s.render(input);
	return result;
}

