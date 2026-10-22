module milktea;

import std::core::dstring;
import std::thread;

// Like ai-harness: a worker can post many stream chunks and then a completion
// or approval request before the UI gets another chance to drain the queue.
struct SendBurst {
	sz initial;
	sz followup;
	sz received;
	bool done;
	bool threaded;
}

fn void SendBurst.post_initial(&self) {
	for (sz i = 0; i < self.initial; i++) g_program.send({ .kind = MsgKind.USER, .tag = (int)i });
	if (self.followup == 0) g_program.send({ .kind = MsgKind.USER, .tag = -1 });
}

fn int send_burst_worker(void* ctx) @local {
	((SendBurst*)ctx).post_initial();
	return 0;
}

fn Cmd SendBurst.init(&self) @dynamic {
	if (self.threaded) {
		thread::Thread worker;
		worker.create(&send_burst_worker, self)!!;
		worker.join()!!;
	} else {
		self.post_initial();
	}
	return null;
}

fn Cmd SendBurst.update(&self, Msg msg) @dynamic {
	if (msg.kind != MsgKind.USER) return null;
	if (msg.tag == -1) { self.done = true; return quit(); }
	assert(msg.tag == self.received, "stream chunks must stay in order");
	self.received++;
	if (msg.tag == 0 && self.followup > 0) {
		for (sz i = 0; i < self.followup; i++) {
			g_program.send({ .kind = MsgKind.USER, .tag = (int)(self.initial + i) });
		}
		g_program.send({ .kind = MsgKind.USER, .tag = -1 });
	}
	return null;
}

fn Node* SendBurst.view(&self) @dynamic { return text("stream burst"); }

fn void test_send_delivers_a_burst_and_completion_across_runs() @test {
	SendBurst model = { .initial = 128 };
	DString out = dstring::temp();
	Program program = @test_program(&model, &out, 80, 24);
	for (sz run = 0; run < 2; run++) {
		model.received = 0;
		model.done = false;
		program.run()!!;
		assert(model.received == 128 && model.done);
		assert(program.send_queue.len == 0, "shutdown releases queue storage");
	}
}

fn void test_send_grows_after_the_ring_wraps() @test {
	SendBurst model = { .initial = 8, .followup = 128 };
	DString out = dstring::temp();
	Program program = @test_program(&model, &out, 80, 24);
	program.run()!!;
	assert(model.received == 136 && model.done);
}

fn void test_send_grows_on_a_worker_and_frees_on_the_main_thread() @test {
	SendBurst model = { .initial = 128, .threaded = true };
	DString out = dstring::temp();
	Program program = @test_program(&model, &out, 80, 24);
	program.run()!!;
	assert(model.received == 128 && model.done);
	assert(program.send_queue.len == 0);
}

fn void test_send_outside_a_run_does_not_allocate_or_deliver() @test {
	SendBurst model = { .initial = 1 };
	DString out = dstring::temp();
	Program program = @test_program(&model, &out, 80, 24);
	program.send({ .kind = MsgKind.QUIT });
	assert(program.send_queue.len == 0);
	program.run()!!;
	assert(model.received == 1 && model.done);
	program.send({ .kind = MsgKind.QUIT });
	assert(program.send_queue.len == 0 && program.send_inflight.load() == 0);
}
