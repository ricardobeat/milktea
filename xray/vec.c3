// Vec is a growable array: what the std List does here, without the
// to_format method every List carries, which keeps the whole text formatter
// in any program that has a List, printing or not.
module xray::vec <Type>;

import std::core::mem;

struct Vec {
	Allocator allocator;
	Type* data;
	sz count;
	sz cap;
}

fn void Vec.init(&self, Allocator a) {
	*self = { .allocator = a };
}

fn void Vec.push(&self, Type v) {
	if (self.count == self.cap) {
		if (self.allocator == null) self.allocator = mem;
		self.cap = self.cap == 0 ? 8 : self.cap * 2;
		self.data = alloc::realloc(self.allocator, self.data, Type::size * self.cap);
	}
	self.data[self.count++] = v;
}

fn void Vec.clear(&self) => self.count = 0;

fn void Vec.free(&self) {
	if (self.data != null) alloc::free(self.allocator, self.data);
	self.data = null;
	self.count = 0;
	self.cap = 0;
}

fn bool Vec.is_initialized(&self) => self.allocator != null;
fn sz Vec.len(&self) @operator(len) => self.count;
fn Type Vec.get(&self, sz i) @operator([]) => self.data[i];
fn Type* Vec.get_ref(&self, sz i) @operator(&[]) => &self.data[i];
fn Type[] Vec.array_view(&self) => self.data[:self.count];
