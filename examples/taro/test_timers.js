// test_timers.js — timer and Promise tests (no network required)
let passed = 0, failed = 0;

function assert(cond, name) {
  if (cond) {
    passed++;
  } else {
    failed++;
    console.log("FAIL: " + name);
  }
}

// setTimeout 0 fires
setTimeout(() => assert(true, "setTimeout 0 fires"), 0);

// setTimeout with delay fires
setTimeout(() => assert(true, "setTimeout 10ms fires"), 10);

// clearTimeout prevents firing
let cancel_id = setTimeout(() => assert(false, "cleared timeout must not fire"), 5);
clearTimeout(cancel_id);

// Ordering: 20ms fires before 30ms, after 10ms
let order = [];
setTimeout(() => { order.push("a"); }, 20);
setTimeout(() => { order.push("b"); }, 10);
setTimeout(() => {
  assert(order[0] === "b" && order[1] === "a", "setTimeout fires in delay order (10ms before 20ms)");
}, 30);

// Promise.resolve
Promise.resolve(42).then(v => assert(v === 42, "Promise.resolve(42).then"));

// Promise.reject
Promise.reject("err").catch(e => assert(e === "err", "Promise.reject.catch"));

// Promise from setTimeout
new Promise(resolve => setTimeout(() => resolve("async"), 5))
  .then(v => assert(v === "async", "Promise resolved from setTimeout"));

// Promise chaining
Promise.resolve(1)
  .then(v => v + 1)
  .then(v => assert(v === 2, "Promise chain: 1 -> 2"));

// Nested setTimeouts
let nested_fired = false;
setTimeout(() => {
  setTimeout(() => { nested_fired = true; }, 10);
}, 5);
setTimeout(() => {
  assert(nested_fired, "nested setTimeout fires");
}, 50);

// Final report and quit
setTimeout(() => {
  console.log("Timer tests: " + passed + " passed, " + failed + " failed");
  if (failed === 0) console.log("ALL PASSED");
  return milktea.quit();
}, 200);

milktea.run({
  init() {},
  update(msg) {
    if (msg.kind === "key" && msg.code === "q") return milktea.quit();
  },
  view() {
    return h("col", {},
      h("text", {}, "Running timer tests... (q to quit early)"),
      h("text", { fg: "#888888" }, "passed=" + passed + " failed=" + failed),
    );
  },
});
