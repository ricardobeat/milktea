module clock;

// 5x5 digit bitmasks. digit(d, row) returns the row mask for digit d.
// MSB = leftmost column. Read row-by-row: top to bottom.
//   0
//  1   2
//   3
//  4   5
//   6
fn int digit(int d, int row) {
	switch (d) {
		case 0: switch (row) {
			case 0: return 0b01110;
			case 1: return 0b10001;
			case 2: return 0b10001;
			case 3: return 0b10001;
			default: return 0b01110;
		}
		case 1: switch (row) {
			case 0: return 0b00100;
			case 1: return 0b01100;
			case 2: return 0b00100;
			case 3: return 0b00100;
			default: return 0b01110;
		}
		case 2: switch (row) {
			case 0: return 0b01110;
			case 1: return 0b00001;
			case 2: return 0b01110;
			case 3: return 0b10000;
			default: return 0b01110;
		}
		case 3: switch (row) {
			case 0: return 0b01110;
			case 1: return 0b00001;
			case 2: return 0b00110;
			case 3: return 0b00001;
			default: return 0b01110;
		}
		case 4: switch (row) {
			case 0: return 0b10001;
			case 1: return 0b10001;
			case 2: return 0b01110;
			case 3: return 0b00001;
			default: return 0b00001;
		}
		case 5: switch (row) {
			case 0: return 0b01110;
			case 1: return 0b10000;
			case 2: return 0b01110;
			case 3: return 0b00001;
			default: return 0b01110;
		}
		case 6: switch (row) {
			case 0: return 0b01110;
			case 1: return 0b10000;
			case 2: return 0b01110;
			case 3: return 0b10001;
			default: return 0b01110;
		}
		case 7: switch (row) {
			case 0: return 0b01110;
			case 1: return 0b00001;
			case 2: return 0b00010;
			case 3: return 0b00100;
			default: return 0b01000;
		}
		case 8: switch (row) {
			case 0: return 0b01110;
			case 1: return 0b10001;
			case 2: return 0b01110;
			case 3: return 0b10001;
			default: return 0b01110;
		}
		default: switch (row) {
			case 0: return 0b01110;
			case 1: return 0b10001;
			case 2: return 0b01110;
			case 3: return 0b00001;
			default: return 0b01110;
		}
	}
}
